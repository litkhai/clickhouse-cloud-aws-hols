variable "aws_region" {
  description = "AWS region to deploy resources. If not set, uses AWS_REGION or AWS_DEFAULT_REGION environment variable, or defaults to us-east-1"
  type        = string
  default     = null
}

variable "instance_name" {
  description = "Name tag for the EC2 instance"
  type        = string
  default     = "minio-server"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "c5.xlarge"
}

variable "ebs_volume_size" {
  description = "Size of the EBS volume in GB"
  type        = number
  default     = 250
}

variable "key_pair_name" {
  description = "Name of the EC2 key pair for SSH access. If not provided, SSH access will not be available"
  type        = string
  default     = null
}

variable "allowed_cidr_blocks" {
  description = "List of CIDR blocks allowed to access MinIO"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "minio_root_user" {
  description = "MinIO root username (min 3 characters)"
  type        = string
  default     = "admin"
}

variable "minio_root_password" {
  description = "MinIO root password (min 8 characters)"
  type        = string
  sensitive   = true
  default     = "admin"
}

variable "minio_data_dir" {
  description = "Directory path for MinIO data storage"
  type        = string
  default     = "/mnt/data"
}

variable "use_elastic_ip" {
  description = "Whether to allocate and associate an Elastic IP"
  type        = bool
  default     = true
}
