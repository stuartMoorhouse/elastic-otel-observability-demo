# -----------------------------------------------------------------------------
# Elastic Cloud Deployment
# -----------------------------------------------------------------------------

resource "ec_deployment" "this" {
  name                   = var.project_name
  region                 = var.elastic_region
  version                = data.ec_stack.latest.version
  deployment_template_id = "general-purpose"

  elasticsearch = {
    hot = {
      autoscaling = {}
    }

    ml = {
      autoscaling = {
        max_size          = "8g"
        max_size_resource = "memory"
      }
      size          = "8g"
      size_resource = "memory"
      zone_count    = 1
    }
  }

  kibana = {}
}

# -----------------------------------------------------------------------------
# Create a dedicated API key for data shipping
# Uses terraform_data + external script to avoid data source race condition
# Credentials written to temp file to keep them out of the process table
# -----------------------------------------------------------------------------

resource "terraform_data" "elastic_api_key" {
  depends_on = [ec_deployment.this]

  input = {
    es_endpoint = ec_deployment.this.elasticsearch.https_endpoint
    username    = ec_deployment.this.elasticsearch_username
    password    = ec_deployment.this.elasticsearch_password
    key_name    = "${var.project_name}-shipping-key"
  }

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ../state
      CURL_AUTH=$(mktemp) && chmod 600 "$CURL_AUTH"
      printf 'user = "%s:%s"\n' "${self.input.username}" "${self.input.password}" > "$CURL_AUTH"

      curl -s -X POST "${self.input.es_endpoint}/_security/api_key" \
        -H "Content-Type: application/json" \
        -K "$CURL_AUTH" \
        -d '{
          "name": "${self.input.key_name}",
          "role_descriptors": {
            "otel_shipper": {
              "cluster": ["monitor", "manage_index_templates", "manage_ilm", "manage_pipeline", "cluster:admin/ingest/pipeline/put"],
              "index": [
                {
                  "names": ["logs-*", "metrics-*", "traces-*", "apm-*", ".ds-*"],
                  "privileges": ["auto_configure", "create_doc", "create_index", "write", "read", "view_index_metadata"]
                }
              ]
            }
          },
          "expiration": "365d"
        }' > ../state/api-key-response.json

      rm -f "$CURL_AUTH"
    EOT
  }
}

# Read API key via external data source — runs at apply time after the provisioner
data "external" "api_key" {
  depends_on = [terraform_data.elastic_api_key]

  program = ["bash", "-c", <<-EOT
    if [ -f "${path.module}/../state/api-key-response.json" ]; then
      cat "${path.module}/../state/api-key-response.json"
    else
      echo '{"encoded":"","id":"","name":"","api_key":""}'
    fi
  EOT
  ]
}

locals {
  # The encoded API key (base64 of id:api_key) for use in Authorization header
  elastic_api_key = data.external.api_key.result.encoded
}
