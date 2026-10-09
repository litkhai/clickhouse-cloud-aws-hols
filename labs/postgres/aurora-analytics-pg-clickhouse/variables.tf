variable "aws_region" {
  description = "AWS region for every resource"
  type        = string
  default     = "ap-northeast-2"
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
  description = "Value of the ttl tag on every resource, e.g. \"2026-10-20\" (when this lab should be gone)"
  type        = string

  validation {
    condition     = length(var.ttl) > 0
    error_message = "ttl must not be empty."
  }
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to SSH to the generator and the PostgreSQL front end"
  type        = list(string)

  # Deliberately no default. These blocks open SSH on two instances with public
  # IPs, so a default of 0.0.0.0/0 would put them on the internet for anyone who
  # ran terraform apply without reading the example first.
  validation {
    condition     = length(var.allowed_cidr_blocks) > 0 && !contains(var.allowed_cidr_blocks, "0.0.0.0/0")
    error_message = "allowed_cidr_blocks must not be empty and must not contain 0.0.0.0/0. Use your own address, e.g. [\"$(curl -s ifconfig.me)/32\"]."
  }
}

variable "key_name" {
  description = "Existing EC2 key pair for SSH. Empty = no key pair; reach the instances with SSM Session Manager / send-command (the instance profile carries AmazonSSMManagedInstanceCore)"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------- Aurora

variable "create_aurora" {
  description = "Create the Aurora cluster, its instance and the AuroraAnalytics role association"
  type        = bool
  default     = true
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version. aurora_analytics needs 17.11+ or 18.6+ (AWS docs, read 2026-10-09)"
  type        = string
  default     = "17.11"

  validation {
    condition     = can(regex("^(17|18)\\.[0-9]+$", var.aurora_engine_version))
    error_message = "aurora_engine_version must look like 17.11 or 18.6 (major 17 or 18)."
  }
}

variable "pg_major" {
  description = "PostgreSQL major version of the front end (pg_clickhouse image tag and the client packages on the generator). Must equal the major of aurora_engine_version"
  type        = string
  default     = "17"

  validation {
    condition     = contains(["17", "18"], var.pg_major)
    error_message = "pg_major must be 17 or 18 (the pg_clickhouse tags 17-0.11.0 and 18-0.11.0 exist, read 2026-10-09)."
  }
}

variable "aurora_instance_class" {
  description = "Instance class of the one Aurora instance. This is what changes between test targets"
  type        = string
  default     = "db.t4g.large"

  validation {
    condition     = contains(["db.t4g.medium", "db.t4g.large", "db.serverless", "db.r8g.large", "db.r8gd.xlarge"], var.aurora_instance_class)
    error_message = "aurora_instance_class must be one of db.t4g.medium, db.t4g.large, db.serverless, db.r8g.large, db.r8gd.xlarge."
  }
}

variable "aurora_storage_type" {
  description = "\"\" for Aurora Standard, \"aurora-iopt1\" for Aurora I/O-Optimized"
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "aurora-iopt1"], var.aurora_storage_type)
    error_message = "aurora_storage_type must be \"\" (Aurora Standard) or \"aurora-iopt1\" (I/O-Optimized)."
  }
}

variable "serverless_min_acu" {
  description = "Serverless v2 minimum ACU (used only when aurora_instance_class is db.serverless)"
  type        = number
  default     = 0.5
}

variable "serverless_max_acu" {
  description = "Serverless v2 maximum ACU (used only when aurora_instance_class is db.serverless)"
  type        = number
  default     = 8
}

variable "extra_cluster_parameters" {
  description = "Extra cluster parameters for the later tuned run, name => value. Applied at the next reboot (pending-reboot), so dynamic and static parameters both work"
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------- EC2

variable "create_generator" {
  description = "Create the generator/client EC2 (DuckDB, pgbench, clickhouse client)"
  type        = bool
  default     = true
}

variable "generator_instance_type" {
  description = "Instance type of the generator (arm64 only: the AMI and the user data are arm64)"
  type        = string
  default     = "m7g.4xlarge"
}

variable "generator_disk_gb" {
  description = "Root volume (gp3) of the generator in GB; TPC-DS data is generated here before it is uploaded"
  type        = number
  default     = 500
}

variable "create_pgfront" {
  description = "Create the PostgreSQL front end EC2 running pg_clickhouse. Off by default: the run uses a ClickHouse Managed Postgres service as the front end (owner's choice, 2026-10-09); this EC2 is the self-managed alternative"
  type        = bool
  default     = false
}

variable "pgfront_instance_type" {
  description = "Instance type of the PostgreSQL front end"
  type        = string
  default     = "t4g.large"

  validation {
    condition     = contains(["t4g.medium", "t4g.large"], var.pgfront_instance_type)
    error_message = "pgfront_instance_type must be t4g.medium or t4g.large."
  }
}

# ---------------------------------------------------------------- ClickHouse Cloud

variable "chc_iam_role_arn" {
  description = "IAM role ARN of the ClickHouse Cloud service (console: service settings, Network security information). Empty = do not create the role ClickHouse Cloud assumes to read the bucket"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------- Glue catalog + Iceberg

variable "enable_glue" {
  description = "Create the Glue catalog databases, the Glue interface endpoint, the Athena workgroup and the matching IAM permissions (the optional Iceberg variant; README \"Glue catalog and Iceberg\"). Turning it on adds resources and edits IAM policy documents in place"
  type        = bool
  default     = false
}
