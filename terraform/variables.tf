variable "aws_region" {
  description = "AWS region for infrastructure deployment"
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "AWS CLI profile name (optional, uses default credential chain if null)"
  type        = string
  default     = null
}

variable "allowed_cidr" {
  description = "CIDR block allowed to access the EC2 instance (auto-detected from deployer IP if null)"
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type for the demo application host"
  type        = string
  default     = "t3.large"
}

variable "elastic_region" {
  description = "Elastic Cloud deployment region"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Project name used as resource name prefix and tags"
  type        = string
  default     = "otel-elastic-demo"
}

variable "aws_tags" {
  description = "Default tags applied to all AWS resources"
  type        = map(string)
  default     = {}
}
