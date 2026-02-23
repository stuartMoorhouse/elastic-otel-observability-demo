# -----------------------------------------------------------------------------
# Elastic Synthetics Monitors
# Created via Kibana API using null_resource + curl
# -----------------------------------------------------------------------------

resource "null_resource" "synthetics_health_monitor" {
  depends_on = [
    aws_instance.this,
    ec_deployment.this,
  ]

  triggers = {
    ec2_ip = aws_instance.this.public_ip
  }

  provisioner "local-exec" {
    command = <<-EOT
      sleep 30
      CURL_AUTH=$(mktemp) && chmod 600 "$CURL_AUTH"
      printf 'user = "%s:%s"\n' "${ec_deployment.this.elasticsearch_username}" "${ec_deployment.this.elasticsearch_password}" > "$CURL_AUTH"

      curl -s -X POST "${ec_deployment.this.kibana.https_endpoint}/api/synthetics/monitors" \
        -H "Content-Type: application/json" \
        -H "kbn-xsrf: true" \
        -K "$CURL_AUTH" \
        -d '{
          "type": "http",
          "name": "${var.project_name} - API Health Check",
          "urls": "http://${aws_instance.this.public_ip}/api/health",
          "schedule": { "number": 1, "unit": "m" },
          "locations": [{ "id": "europe_west_1_gcp", "label": "Europe - United Kingdom", "isServiceManaged": true }],
          "enabled": true,
          "tags": ["${var.project_name}", "health-check"],
          "alert": { "status": { "enabled": true } },
          "timeout": "30",
          "max_redirects": "3",
          "response": {},
          "check": { "response": { "status": [200] } }
        }'

      rm -f "$CURL_AUTH"
    EOT
  }
}

resource "null_resource" "synthetics_homepage_monitor" {
  depends_on = [
    aws_instance.this,
    ec_deployment.this,
  ]

  triggers = {
    ec2_ip = aws_instance.this.public_ip
  }

  provisioner "local-exec" {
    command = <<-EOT
      sleep 35
      CURL_AUTH=$(mktemp) && chmod 600 "$CURL_AUTH"
      printf 'user = "%s:%s"\n' "${ec_deployment.this.elasticsearch_username}" "${ec_deployment.this.elasticsearch_password}" > "$CURL_AUTH"

      curl -s -X POST "${ec_deployment.this.kibana.https_endpoint}/api/synthetics/monitors" \
        -H "Content-Type: application/json" \
        -H "kbn-xsrf: true" \
        -K "$CURL_AUTH" \
        -d '{
          "type": "http",
          "name": "${var.project_name} - Homepage",
          "urls": "http://${aws_instance.this.public_ip}/",
          "schedule": { "number": 1, "unit": "m" },
          "locations": [{ "id": "europe_west_1_gcp", "label": "Europe - United Kingdom", "isServiceManaged": true }],
          "enabled": true,
          "tags": ["${var.project_name}", "homepage"],
          "alert": { "status": { "enabled": true } },
          "timeout": "30",
          "max_redirects": "3",
          "response": {},
          "check": { "response": { "status": [200] } }
        }'

      rm -f "$CURL_AUTH"
    EOT
  }
}
