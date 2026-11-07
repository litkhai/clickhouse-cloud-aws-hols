variable "aws_region" {
  description = "AWS region for every resource (the ClickHouse Cloud service must be in the same region)"
  type        = string
  default     = "ap-northeast-2"
}

variable "az" {
  description = "Availability zone for the client EC2 and the Valkey node (same AZ, so the cache is one hop away)"
  type        = string
  default     = "ap-northeast-2a"
}

variable "owner" {
  description = "Value of the owner tag on every resource (who to ask before deleting it)"
  type        = string

  validation {
    condition     = length(var.owner) > 0
    error_message = "owner must not be empty."
  }
}

variable "ttl" {
  description = "Value of the ttl tag on every resource, e.g. \"2026-11-14\" (when this lab should be gone)"
  type        = string

  validation {
    condition     = length(var.ttl) > 0
    error_message = "ttl must not be empty."
  }
}

variable "client_instance_type" {
  description = "EC2 instance type of the load client (arm64: the binary is built for linux/arm64)"
  type        = string
  default     = "c7g.2xlarge"
}

variable "valkey_node_type" {
  description = "ElastiCache node type of the single Valkey node"
  type        = string
  default     = "cache.r7g.large"
}

variable "valkey_engine_version" {
  description = "ElastiCache for Valkey engine version (deploy.sh checks it is offered in the region)"
  type        = string
  default     = "8.1"
}

variable "valkey_parameter_group" {
  description = "Parameter group family default for that engine version"
  type        = string
  default     = "default.valkey8"
}
