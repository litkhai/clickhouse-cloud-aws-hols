variable "aws_region" {
  description = "AWS region to deploy resources. If not set, uses AWS_REGION or AWS_DEFAULT_REGION environment variable, or defaults to us-east-1"
  type        = string
  default     = null
}

variable "instance_name" {
  description = "Name tag for the EC2 instance"
  type        = string
  default     = "confluent-server"
}

variable "instance_type" {
  description = "EC2 instance type (minimum r5.xlarge recommended for Confluent Platform)"
  type        = string
  default     = "r5.xlarge"
}

variable "ebs_volume_size" {
  description = "Size of the EBS volume in GB"
  type        = number
  default     = 100
}

variable "key_pair_name" {
  description = "Name of the EC2 key pair for SSH access. If not provided, SSH access will not be available"
  type        = string
  default     = null
}

variable "allowed_cidr_blocks" {
  description = "List of CIDR blocks allowed to access Confluent Platform"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "use_elastic_ip" {
  description = "Whether to allocate and associate an Elastic IP"
  type        = bool
  default     = false
}

variable "confluent_version" {
  description = "Confluent Platform version tag"
  type        = string
  default     = "7.5.0"
}

variable "sample_topic_name" {
  description = "Name of the sample topic to create"
  type        = string
  default     = "sample-data-topic"
}

variable "data_producer_interval" {
  description = "Interval in seconds for producing sample data"
  type        = number
  default     = 5

  validation {
    condition     = var.data_producer_interval > 0
    error_message = "Data producer interval must be greater than 0 seconds."
  }
}

variable "kafka_sasl_username" {
  description = "Kafka SASL username (API Key)"
  type        = string
  default     = "admin"
}

variable "kafka_sasl_password" {
  description = "Kafka SASL password (API Secret)"
  type        = string
  default     = "admin-secret"
  sensitive   = true
}