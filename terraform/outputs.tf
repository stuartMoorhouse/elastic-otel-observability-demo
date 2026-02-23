# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "elasticsearch_url" {
  description = "Elasticsearch cluster HTTPS endpoint"
  value       = ec_deployment.this.elasticsearch.https_endpoint
}

output "kibana_url" {
  description = "Kibana HTTPS endpoint"
  value       = ec_deployment.this.kibana.https_endpoint
}

output "ec2_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.this.public_ip
}

output "ssh_command" {
  description = "SSH command to connect to the EC2 instance"
  value       = "ssh -i state/ssh-key.pem ubuntu@${aws_instance.this.public_ip}"
}

output "app_url" {
  description = "URL of the demo application"
  value       = "http://${aws_instance.this.public_ip}"
}

output "deployment_id" {
  description = "Elastic Cloud deployment ID"
  value       = ec_deployment.this.id
  sensitive   = true
}

output "elasticsearch_username" {
  description = "Elasticsearch admin username"
  value       = ec_deployment.this.elasticsearch_username
  sensitive   = true
}

output "elasticsearch_password" {
  description = "Elasticsearch admin password"
  value       = ec_deployment.this.elasticsearch_password
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Write connection info to local file for easy reference
# -----------------------------------------------------------------------------

resource "local_file" "connection_info" {
  filename        = "${path.module}/../state/connection-info.txt"
  file_permission = "0600"

  content = <<-EOT
    ============================================================
    ${var.project_name} — Connection Information
    ============================================================

    Elasticsearch URL : ${ec_deployment.this.elasticsearch.https_endpoint}
    Kibana URL        : ${ec_deployment.this.kibana.https_endpoint}
    Deployment ID     : ${ec_deployment.this.id}

    ES Username       : ${ec_deployment.this.elasticsearch_username}
    ES Password       : ${ec_deployment.this.elasticsearch_password}

    EC2 Public IP     : ${aws_instance.this.public_ip}
    Application URL   : http://${aws_instance.this.public_ip}
    SSH Command       : ssh -i state/ssh-key.pem ubuntu@${aws_instance.this.public_ip}

    ============================================================
  EOT
}
