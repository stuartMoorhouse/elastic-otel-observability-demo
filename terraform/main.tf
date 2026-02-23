terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    ec = {
      source  = "elastic/ec"
      version = "~> 0.12"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Providers
# -----------------------------------------------------------------------------

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = var.aws_tags
  }
}

# Elastic Cloud provider — authenticates via EC_API_KEY environment variable
provider "ec" {}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

# Auto-detect deployer's public IP for security group rules
data "http" "deployer_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  # checkip.amazonaws.com returns IP with trailing newline
  deployer_ip  = trimspace(data.http.deployer_ip.response_body)
  allowed_cidr = var.allowed_cidr != null ? var.allowed_cidr : "${local.deployer_ip}/32"
}

# Get the latest Elastic Cloud stack version
data "ec_stack" "latest" {
  version_regex = "latest"
  region        = var.elastic_region
}
