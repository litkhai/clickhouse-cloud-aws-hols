variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "owner" {
  description = "owner tag on every resource (who to ask before deleting it)"
  type        = string
  validation {
    condition     = length(var.owner) > 0
    error_message = "owner must not be empty."
  }
}

variable "ttl" {
  description = "ttl tag on every resource, e.g. \"2026-11-13\""
  type        = string
  validation {
    condition     = length(var.ttl) > 0
    error_message = "ttl must not be empty."
  }
}

variable "allowed_cidr_blocks" {
  description = "Operator CIDR blocks allowed to reach PostgreSQL (to load data and run checks)"
  type        = list(string)
  validation {
    condition     = length(var.allowed_cidr_blocks) > 0 && !contains(var.allowed_cidr_blocks, "0.0.0.0/0")
    error_message = "allowed_cidr_blocks must not be empty and must not contain 0.0.0.0/0. Use your own address, e.g. [\"$(curl -s ifconfig.me)/32\"]."
  }
}

variable "clickpipes_ips" {
  description = "ClickPipes egress IPs for the ClickHouse Cloud service's region"
  type        = list(string)
  default     = ["3.38.68.69", "52.78.68.128", "13.209.152.13", "3.38.24.84", "3.37.159.31", "3.34.25.104"]
}

variable "api_allowed_source_ips" {
  description = "Who may call the decrypt API: ClickHouse Cloud egress IPs of the service's region (https://api.clickhouse.cloud/static-ips.json, \"egress_ips\")"
  type        = list(string)
  validation {
    condition     = length(var.api_allowed_source_ips) > 0
    error_message = "api_allowed_source_ips must list the ClickHouse Cloud egress IPs."
  }
}

variable "lambda_memory_mb" {
  type    = number
  default = 1024
}

variable "aurora_engine_version" {
  type    = string
  default = "16.13"
}

variable "aurora_instance_class" {
  type    = string
  default = "db.t4g.medium"
}
