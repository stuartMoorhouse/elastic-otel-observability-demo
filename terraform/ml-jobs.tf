# -----------------------------------------------------------------------------
# ML Anomaly Detection Jobs
# Created via Elasticsearch ML API using null_resource + curl
#
# Field names use OTel Collector hostmetrics output (NOT Elastic Agent/Metricbeat)
# Index patterns match elasticsearch exporter with mapping.mode: ecs
# -----------------------------------------------------------------------------

locals {
  es_url = ec_deployment.this.elasticsearch.https_endpoint
}

# Helper: all ML curl commands use credential file to avoid process table exposure
# Each resource writes creds to a temp file, uses -K, then removes it.

# ---------------------------------------------------------------------------
# 1. APM Transaction Duration Anomaly Detection
# ---------------------------------------------------------------------------

resource "null_resource" "ml_apm_transaction_duration" {
  depends_on = [ec_deployment.this]

  triggers = {
    deployment_id = ec_deployment.this.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      CURL_AUTH=$(mktemp) && chmod 600 "$CURL_AUTH"
      printf 'user = "%s:%s"\n' "${ec_deployment.this.elasticsearch_username}" "${ec_deployment.this.elasticsearch_password}" > "$CURL_AUTH"

      # Create the job
      curl -s -X PUT "${local.es_url}/_ml/anomaly_detectors/${var.project_name}-apm-transaction-duration" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "description": "Detect anomalies in APM transaction duration",
          "analysis_config": {
            "bucket_span": "5m",
            "detectors": [
              {
                "function": "high_mean",
                "field_name": "transaction.duration.us",
                "partition_field_name": "service.name",
                "detector_description": "High mean transaction duration by service"
              }
            ],
            "influencers": ["service.name", "transaction.name", "transaction.type"]
          },
          "data_description": {
            "time_field": "@timestamp"
          },
          "analysis_limits": {
            "model_memory_limit": "256mb"
          },
          "results_index_name": "custom-${var.project_name}"
        }'

      # Create the datafeed — OTel traces go to traces-* indices
      curl -s -X PUT "${local.es_url}/_ml/datafeeds/datafeed-${var.project_name}-apm-transaction-duration" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "job_id": "${var.project_name}-apm-transaction-duration",
          "indices": ["traces-*"],
          "query": {
            "bool": {
              "filter": [
                { "exists": { "field": "transaction.duration.us" } }
              ]
            }
          }
        }'

      # Start the datafeed
      curl -s -X POST "${local.es_url}/_ml/datafeeds/datafeed-${var.project_name}-apm-transaction-duration/_start" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH"

      rm -f "$CURL_AUTH"
    EOT
  }
}

# ---------------------------------------------------------------------------
# 2. APM Error Rate Anomaly Detection
# ---------------------------------------------------------------------------

resource "null_resource" "ml_apm_error_rate" {
  depends_on = [ec_deployment.this]

  triggers = {
    deployment_id = ec_deployment.this.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      CURL_AUTH=$(mktemp) && chmod 600 "$CURL_AUTH"
      printf 'user = "%s:%s"\n' "${ec_deployment.this.elasticsearch_username}" "${ec_deployment.this.elasticsearch_password}" > "$CURL_AUTH"

      curl -s -X PUT "${local.es_url}/_ml/anomaly_detectors/${var.project_name}-apm-error-rate" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "description": "Detect anomalies in APM error rate",
          "analysis_config": {
            "bucket_span": "5m",
            "detectors": [
              {
                "function": "high_count",
                "partition_field_name": "service.name",
                "detector_description": "High error count by service"
              }
            ],
            "influencers": ["service.name", "error.exception.type", "error.grouping_key"]
          },
          "data_description": {
            "time_field": "@timestamp"
          },
          "analysis_limits": {
            "model_memory_limit": "256mb"
          },
          "results_index_name": "custom-${var.project_name}"
        }'

      curl -s -X PUT "${local.es_url}/_ml/datafeeds/datafeed-${var.project_name}-apm-error-rate" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "job_id": "${var.project_name}-apm-error-rate",
          "indices": ["traces-*"],
          "query": {
            "bool": {
              "filter": [
                { "exists": { "field": "error.exception.type" } }
              ]
            }
          }
        }'

      curl -s -X POST "${local.es_url}/_ml/datafeeds/datafeed-${var.project_name}-apm-error-rate/_start" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH"

      rm -f "$CURL_AUTH"
    EOT
  }
}

# ---------------------------------------------------------------------------
# 3. APM Throughput Anomaly Detection
# ---------------------------------------------------------------------------

resource "null_resource" "ml_apm_throughput" {
  depends_on = [ec_deployment.this]

  triggers = {
    deployment_id = ec_deployment.this.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      CURL_AUTH=$(mktemp) && chmod 600 "$CURL_AUTH"
      printf 'user = "%s:%s"\n' "${ec_deployment.this.elasticsearch_username}" "${ec_deployment.this.elasticsearch_password}" > "$CURL_AUTH"

      curl -s -X PUT "${local.es_url}/_ml/anomaly_detectors/${var.project_name}-apm-throughput" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "description": "Detect anomalies in APM transaction throughput",
          "analysis_config": {
            "bucket_span": "5m",
            "detectors": [
              {
                "function": "count",
                "partition_field_name": "service.name",
                "detector_description": "Unusual transaction throughput by service"
              }
            ],
            "influencers": ["service.name", "transaction.name", "transaction.type"]
          },
          "data_description": {
            "time_field": "@timestamp"
          },
          "analysis_limits": {
            "model_memory_limit": "256mb"
          },
          "results_index_name": "custom-${var.project_name}"
        }'

      curl -s -X PUT "${local.es_url}/_ml/datafeeds/datafeed-${var.project_name}-apm-throughput" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "job_id": "${var.project_name}-apm-throughput",
          "indices": ["traces-*"],
          "query": {
            "match_all": {}
          }
        }'

      curl -s -X POST "${local.es_url}/_ml/datafeeds/datafeed-${var.project_name}-apm-throughput/_start" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH"

      rm -f "$CURL_AUTH"
    EOT
  }
}

# ---------------------------------------------------------------------------
# 4. Host CPU Usage Anomaly Detection
# OTel hostmetrics field: system.cpu.utilization
# ---------------------------------------------------------------------------

resource "null_resource" "ml_host_cpu" {
  depends_on = [ec_deployment.this]

  triggers = {
    deployment_id = ec_deployment.this.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      CURL_AUTH=$(mktemp) && chmod 600 "$CURL_AUTH"
      printf 'user = "%s:%s"\n' "${ec_deployment.this.elasticsearch_username}" "${ec_deployment.this.elasticsearch_password}" > "$CURL_AUTH"

      curl -s -X PUT "${local.es_url}/_ml/anomaly_detectors/${var.project_name}-host-cpu-usage" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "description": "Detect anomalies in host CPU usage",
          "analysis_config": {
            "bucket_span": "5m",
            "detectors": [
              {
                "function": "high_mean",
                "field_name": "system.cpu.utilization",
                "partition_field_name": "host.name",
                "detector_description": "High CPU usage by host"
              }
            ],
            "influencers": ["host.name"]
          },
          "data_description": {
            "time_field": "@timestamp"
          },
          "analysis_limits": {
            "model_memory_limit": "128mb"
          },
          "results_index_name": "custom-${var.project_name}"
        }'

      curl -s -X PUT "${local.es_url}/_ml/datafeeds/datafeed-${var.project_name}-host-cpu-usage" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "job_id": "${var.project_name}-host-cpu-usage",
          "indices": ["metrics-*"],
          "query": {
            "bool": {
              "filter": [
                { "exists": { "field": "system.cpu.utilization" } }
              ]
            }
          }
        }'

      curl -s -X POST "${local.es_url}/_ml/datafeeds/datafeed-${var.project_name}-host-cpu-usage/_start" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH"

      rm -f "$CURL_AUTH"
    EOT
  }
}

# ---------------------------------------------------------------------------
# 5. Host Memory Usage Anomaly Detection
# OTel hostmetrics field: system.memory.utilization
# ---------------------------------------------------------------------------

resource "null_resource" "ml_host_memory" {
  depends_on = [ec_deployment.this]

  triggers = {
    deployment_id = ec_deployment.this.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      CURL_AUTH=$(mktemp) && chmod 600 "$CURL_AUTH"
      printf 'user = "%s:%s"\n' "${ec_deployment.this.elasticsearch_username}" "${ec_deployment.this.elasticsearch_password}" > "$CURL_AUTH"

      curl -s -X PUT "${local.es_url}/_ml/anomaly_detectors/${var.project_name}-host-memory-usage" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "description": "Detect anomalies in host memory usage",
          "analysis_config": {
            "bucket_span": "5m",
            "detectors": [
              {
                "function": "high_mean",
                "field_name": "system.memory.utilization",
                "partition_field_name": "host.name",
                "detector_description": "High memory usage by host"
              }
            ],
            "influencers": ["host.name"]
          },
          "data_description": {
            "time_field": "@timestamp"
          },
          "analysis_limits": {
            "model_memory_limit": "128mb"
          },
          "results_index_name": "custom-${var.project_name}"
        }'

      curl -s -X PUT "${local.es_url}/_ml/datafeeds/datafeed-${var.project_name}-host-memory-usage" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "job_id": "${var.project_name}-host-memory-usage",
          "indices": ["metrics-*"],
          "query": {
            "bool": {
              "filter": [
                { "exists": { "field": "system.memory.utilization" } }
              ]
            }
          }
        }'

      curl -s -X POST "${local.es_url}/_ml/datafeeds/datafeed-${var.project_name}-host-memory-usage/_start" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH"

      rm -f "$CURL_AUTH"
    EOT
  }
}

# ---------------------------------------------------------------------------
# 6. Host Disk I/O Anomaly Detection
# OTel hostmetrics field: system.disk.operations
# ---------------------------------------------------------------------------

resource "null_resource" "ml_host_disk_io" {
  depends_on = [ec_deployment.this]

  triggers = {
    deployment_id = ec_deployment.this.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      CURL_AUTH=$(mktemp) && chmod 600 "$CURL_AUTH"
      printf 'user = "%s:%s"\n' "${ec_deployment.this.elasticsearch_username}" "${ec_deployment.this.elasticsearch_password}" > "$CURL_AUTH"

      curl -s -X PUT "${local.es_url}/_ml/anomaly_detectors/${var.project_name}-host-disk-io" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "description": "Detect anomalies in host disk I/O",
          "analysis_config": {
            "bucket_span": "5m",
            "detectors": [
              {
                "function": "high_mean",
                "field_name": "system.disk.operations",
                "partition_field_name": "host.name",
                "detector_description": "High disk I/O operations by host"
              }
            ],
            "influencers": ["host.name"]
          },
          "data_description": {
            "time_field": "@timestamp"
          },
          "analysis_limits": {
            "model_memory_limit": "128mb"
          },
          "results_index_name": "custom-${var.project_name}"
        }'

      curl -s -X PUT "${local.es_url}/_ml/datafeeds/datafeed-${var.project_name}-host-disk-io" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "job_id": "${var.project_name}-host-disk-io",
          "indices": ["metrics-*"],
          "query": {
            "bool": {
              "filter": [
                { "exists": { "field": "system.disk.operations" } }
              ]
            }
          }
        }'

      curl -s -X POST "${local.es_url}/_ml/datafeeds/datafeed-${var.project_name}-host-disk-io/_start" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH"

      rm -f "$CURL_AUTH"
    EOT
  }
}

# ---------------------------------------------------------------------------
# 7. Log Volume Rate Anomaly Detection
# ---------------------------------------------------------------------------

resource "null_resource" "ml_log_volume" {
  depends_on = [ec_deployment.this]

  triggers = {
    deployment_id = ec_deployment.this.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      CURL_AUTH=$(mktemp) && chmod 600 "$CURL_AUTH"
      printf 'user = "%s:%s"\n' "${ec_deployment.this.elasticsearch_username}" "${ec_deployment.this.elasticsearch_password}" > "$CURL_AUTH"

      curl -s -X PUT "${local.es_url}/_ml/anomaly_detectors/${var.project_name}-log-volume-rate" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "description": "Detect anomalies in log volume rate",
          "analysis_config": {
            "bucket_span": "5m",
            "detectors": [
              {
                "function": "count",
                "partition_field_name": "service.name",
                "detector_description": "Unusual log volume by service"
              },
              {
                "function": "high_count",
                "partition_field_name": "log.level",
                "detector_description": "High log count by severity level"
              }
            ],
            "influencers": ["service.name", "log.level", "host.name"]
          },
          "data_description": {
            "time_field": "@timestamp"
          },
          "analysis_limits": {
            "model_memory_limit": "256mb"
          },
          "results_index_name": "custom-${var.project_name}"
        }'

      curl -s -X PUT "${local.es_url}/_ml/datafeeds/datafeed-${var.project_name}-log-volume-rate" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "job_id": "${var.project_name}-log-volume-rate",
          "indices": ["logs-*"],
          "query": {
            "match_all": {}
          }
        }'

      curl -s -X POST "${local.es_url}/_ml/datafeeds/datafeed-${var.project_name}-log-volume-rate/_start" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH"

      rm -f "$CURL_AUTH"
    EOT
  }
}
