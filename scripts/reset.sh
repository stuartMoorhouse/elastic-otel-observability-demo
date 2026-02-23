#!/bin/bash
# ==============================================================================
# Demo Reset Script
# ==============================================================================
# Resets application state (DB, Redis, chaos) and Elastic data streams so the
# demo can be run from a clean slate.
#
# Usage:
#   ./scripts/reset.sh                    # reads state/connection-info.txt
#   ./scripts/reset.sh <ec2_ip> <es_url> <kibana_url> <api_key> <ssh_key>
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONNECTION_FILE="$PROJECT_DIR/state/connection-info.txt"

# ---------------------------------------------------------------------------
# Parse connection info
# ---------------------------------------------------------------------------
if [[ $# -ge 5 ]]; then
    EC2_IP="$1"
    ELASTICSEARCH_URL="$2"
    KIBANA_URL="$3"
    API_KEY="$4"
    SSH_KEY="$5"
elif [[ -f "$CONNECTION_FILE" ]]; then
    echo "Reading connection info from $CONNECTION_FILE ..."
    EC2_IP="$(grep '^EC2_IP=' "$CONNECTION_FILE" | cut -d= -f2-)"
    ELASTICSEARCH_URL="$(grep '^ELASTICSEARCH_URL=' "$CONNECTION_FILE" | cut -d= -f2-)"
    KIBANA_URL="$(grep '^KIBANA_URL=' "$CONNECTION_FILE" | cut -d= -f2-)"
    API_KEY="$(grep '^API_KEY=' "$CONNECTION_FILE" | cut -d= -f2-)"
    SSH_KEY="$(grep '^SSH_KEY=' "$CONNECTION_FILE" | cut -d= -f2-)"
else
    echo "ERROR: No connection info found."
    echo ""
    echo "Usage:"
    echo "  $0"
    echo "  $0 <ec2_ip> <es_url> <kibana_url> <api_key> <ssh_key_path>"
    echo ""
    echo "Or create state/connection-info.txt with:"
    echo "  EC2_IP=..."
    echo "  ELASTICSEARCH_URL=..."
    echo "  KIBANA_URL=..."
    echo "  API_KEY=..."
    echo "  SSH_KEY=..."
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH_USER="ubuntu"

echo "============================================"
echo "  Elastic Observability OTel Demo - RESET"
echo "============================================"
echo ""
echo "EC2 Instance : $EC2_IP"
echo "Elasticsearch: $ELASTICSEARCH_URL"
echo "Kibana       : $KIBANA_URL"
echo ""

# ---------------------------------------------------------------------------
# Step 1 — Reset chaos state via API
# ---------------------------------------------------------------------------
echo "--- Step 1: Resetting chaos injection state ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://${EC2_IP}/api/chaos/reset" 2>/dev/null || true)

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "  Chaos state reset via API (HTTP $HTTP_CODE)"
else
    echo "  WARNING: Could not reach API (HTTP $HTTP_CODE). Will reset on instance directly."
fi

# ---------------------------------------------------------------------------
# Step 2 — Reset application state on EC2
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 2: Resetting application state on EC2 ---"

ssh $SSH_OPTS -i "$SSH_KEY" "${SSH_USER}@${EC2_IP}" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

echo "  Stopping application services..."
sudo systemctl stop loadgen frontend api 2>/dev/null || true
sleep 2

echo "  Resetting PostgreSQL database..."
sudo -u postgres psql -d ecommerce <<'SQL'
-- Truncate all application tables and restart sequences
DO $$
DECLARE
    tbl text;
BEGIN
    FOR tbl IN
        SELECT tablename FROM pg_tables
        WHERE schemaname = 'public'
    LOOP
        EXECUTE format('TRUNCATE TABLE %I CASCADE', tbl);
    END LOOP;
END $$;
SQL
echo "  PostgreSQL tables truncated."

echo "  Flushing Redis..."
redis-cli FLUSHALL
echo "  Redis flushed."

echo "  Truncating application logs..."
sudo truncate -s 0 /var/log/app/*.log 2>/dev/null || true

echo "  Restarting application services..."
sudo systemctl restart api
sleep 3
sudo systemctl restart frontend loadgen

echo "  Application state reset complete."
REMOTE_SCRIPT

echo "  EC2 application state reset done."

# ---------------------------------------------------------------------------
# Step 3 — Reset Elastic data
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 3: Resetting Elastic data streams ---"

ES_AUTH_HEADER="Authorization: ApiKey ${API_KEY}"

# Data stream patterns to delete
DATA_STREAMS=(
    "traces-apm*"
    "traces-apm.rum*"
    "metrics-apm*"
    "metrics-system*"
    "logs-apm*"
    "logs-app*"
    "logs-otel*"
    "metrics-otel*"
    "traces-otel*"
)

for pattern in "${DATA_STREAMS[@]}"; do
    echo "  Deleting data stream: $pattern"
    RESPONSE=$(curl -s -X DELETE \
        "${ELASTICSEARCH_URL}/_data_stream/${pattern}" \
        -H "$ES_AUTH_HEADER" \
        -H "Content-Type: application/json" 2>/dev/null || true)
    ACKED=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('acknowledged',''))" 2>/dev/null || true)
    if [[ "$ACKED" == "True" ]]; then
        echo "    Deleted."
    else
        echo "    Skipped (may not exist)."
    fi
done

# Clean up index patterns that might remain
echo ""
echo "  Cleaning up residual indices..."
for pattern in "traces-apm*" "metrics-apm*" "logs-apm*" "metrics-system*"; do
    curl -s -X DELETE \
        "${ELASTICSEARCH_URL}/${pattern}" \
        -H "$ES_AUTH_HEADER" \
        -H "Content-Type: application/json" > /dev/null 2>&1 || true
done

# ---------------------------------------------------------------------------
# Step 4 — Reset ML jobs (if any)
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 4: Resetting ML anomaly detection jobs ---"

# List ML jobs
ML_JOBS=$(curl -s -X GET \
    "${ELASTICSEARCH_URL}/_ml/anomaly_detectors?pretty" \
    -H "$ES_AUTH_HEADER" \
    -H "Content-Type: application/json" 2>/dev/null || echo "{}")

JOB_IDS=$(echo "$ML_JOBS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    jobs = data.get('jobs', [])
    for j in jobs:
        jid = j.get('job_id', '')
        if 'apm' in jid or 'otel' in jid or 'app' in jid:
            print(jid)
except:
    pass
" 2>/dev/null || true)

if [[ -n "$JOB_IDS" ]]; then
    while IFS= read -r job_id; do
        echo "  Resetting ML job: $job_id"

        # Close the job
        curl -s -X POST \
            "${ELASTICSEARCH_URL}/_ml/anomaly_detectors/${job_id}/_close?force=true" \
            -H "$ES_AUTH_HEADER" \
            -H "Content-Type: application/json" > /dev/null 2>&1 || true

        # Delete model snapshots (keep the empty initial one)
        SNAPSHOTS=$(curl -s -X GET \
            "${ELASTICSEARCH_URL}/_ml/anomaly_detectors/${job_id}/model_snapshots" \
            -H "$ES_AUTH_HEADER" \
            -H "Content-Type: application/json" 2>/dev/null || echo "{}")

        SNAP_IDS=$(echo "$SNAPSHOTS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for s in data.get('model_snapshots', []):
        print(s['snapshot_id'])
except:
    pass
" 2>/dev/null || true)

        while IFS= read -r snap_id; do
            [[ -z "$snap_id" ]] && continue
            curl -s -X DELETE \
                "${ELASTICSEARCH_URL}/_ml/anomaly_detectors/${job_id}/model_snapshots/${snap_id}" \
                -H "$ES_AUTH_HEADER" \
                -H "Content-Type: application/json" > /dev/null 2>&1 || true
        done <<< "$SNAP_IDS"

        # Reopen the job
        curl -s -X POST \
            "${ELASTICSEARCH_URL}/_ml/anomaly_detectors/${job_id}/_open" \
            -H "$ES_AUTH_HEADER" \
            -H "Content-Type: application/json" > /dev/null 2>&1 || true

        echo "    Done."
    done <<< "$JOB_IDS"
else
    echo "  No relevant ML jobs found. Skipping."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo "  Reset complete!"
echo "============================================"
echo ""
echo "The demo application is restarting with fresh state."
echo "New telemetry data will start flowing to Elastic within ~30 seconds."
echo ""
echo "  App:     http://${EC2_IP}"
echo "  Kibana:  ${KIBANA_URL}"
echo ""
