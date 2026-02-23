# -----------------------------------------------------------------------------
# SSH Key Pair
# -----------------------------------------------------------------------------

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "this" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ssh.public_key_openssh

  tags = {
    Name = "${var.project_name}-key"
  }
}

resource "local_file" "ssh_private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/../state/ssh-key.pem"
  file_permission = "0600"
}

# -----------------------------------------------------------------------------
# Ubuntu 22.04 LTS AMI (latest from Canonical)
# -----------------------------------------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name        = "${var.project_name}-sg"
  description = "Security group for ${var.project_name} EC2 instance"

  # SSH access from deployer IP
  ingress {
    description = "SSH from deployer"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.allowed_cidr]
  }

  # HTTP access from deployer IP
  ingress {
    description = "HTTP from deployer"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [local.allowed_cidr]
  }

  # Allow all outbound traffic
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}

# -----------------------------------------------------------------------------
# EC2 Instance
# -----------------------------------------------------------------------------

resource "aws_instance" "this" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.this.key_name
  vpc_security_group_ids      = [aws_security_group.this.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = file("${path.module}/../userdata/setup-podman.sh")

  tags = {
    Name = "${var.project_name}-instance"
  }

  depends_on = [
    ec_deployment.this,
    terraform_data.elastic_api_key,
  ]
}

# -----------------------------------------------------------------------------
# Deploy application via rsync + Podman Compose
# -----------------------------------------------------------------------------

resource "null_resource" "deploy" {
  triggers = {
    instance_id = aws_instance.this.id
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = tls_private_key.ssh.private_key_pem
    host        = aws_instance.this.public_ip
  }

  # Wait for cloud-init to finish (Podman installed)
  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait",
    ]
  }

  # Sync project files to EC2
  provisioner "local-exec" {
    command = <<-EOT
      rsync -az --delete \
        -e "ssh -i ${path.module}/../state/ssh-key.pem -o StrictHostKeyChecking=no" \
        --exclude='.git' \
        --exclude='.terraform' \
        --exclude='terraform/.terraform' \
        --exclude='terraform/*.tfstate*' \
        --exclude='state/' \
        --exclude='userdata/' \
        --exclude='.env' \
        --exclude='__pycache__' \
        ${path.module}/../ ubuntu@${aws_instance.this.public_ip}:/home/ubuntu/app/
    EOT
  }

  # Write .env and start services
  provisioner "remote-exec" {
    inline = [
      "cat > /home/ubuntu/app/.env <<'ENVEOF'",
      "ELASTICSEARCH_URL=${ec_deployment.this.elasticsearch.https_endpoint}",
      "ELASTIC_API_KEY=${local.elastic_api_key}",
      "ENVEOF",
      "cd /home/ubuntu/app && podman-compose up -d --build",
    ]
  }

  depends_on = [
    aws_instance.this,
    local_file.ssh_private_key,
  ]
}
