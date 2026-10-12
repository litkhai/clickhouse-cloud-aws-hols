variable "organization_id" {
  type = string
}

variable "token_key" {
  type      = string
  sensitive = true
}

variable "token_secret" {
  type      = string
  sensitive = true
}

variable "service_id" {
  type = string
}

variable "pipe_name" {
  type    = string
  default = "mask-lab-users"
}

variable "source_url" {
  description = "S3 URL of the Parquet file(s); bash-style wildcards allowed"
  type        = string
  default     = "https://datasets-documentation.s3.eu-west-3.amazonaws.com/stackoverflow/parquet/users.parquet"
}

variable "iam_role_arn" {
  description = "IAM role ClickPipes assumes for a private bucket; null for a public bucket"
  type        = string
  default     = null
}
