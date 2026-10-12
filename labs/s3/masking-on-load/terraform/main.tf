terraform {
  required_version = ">= 1.5"
  required_providers {
    clickhouse = {
      source  = "ClickHouse/clickhouse"
      version = "3.37.0"
    }
  }
}

provider "clickhouse" {
  organization_id = var.organization_id
  token_key       = var.token_key
  token_secret    = var.token_secret
}

locals {
  # Must match mask_lab.users_landing (sql/00-schema.sql). ClickPipes only maps fields;
  # the masking happens in the materialized view behind the Null table.
  columns = [
    { name = "Id", type = "Nullable(Int64)" },
    { name = "Reputation", type = "Nullable(String)" },
    { name = "CreationDate", type = "Nullable(DateTime64(3, 'UTC'))" },
    { name = "DisplayName", type = "Nullable(String)" },
    { name = "LastAccessDate", type = "Nullable(DateTime64(3, 'UTC'))" },
    { name = "AboutMe", type = "Nullable(String)" },
    { name = "Views", type = "Nullable(Int64)" },
    { name = "UpVotes", type = "Nullable(Int64)" },
    { name = "DownVotes", type = "Nullable(Int64)" },
    { name = "WebsiteUrl", type = "Nullable(String)" },
    { name = "Location", type = "Nullable(String)" },
    { name = "AccountId", type = "Nullable(Int64)" },
  ]
}

resource "clickhouse_clickpipe" "users" {
  name       = var.pipe_name
  service_id = var.service_id

  source = {
    object_storage = {
      type          = "s3"
      url           = var.source_url
      format        = "Parquet"
      is_continuous = false # one-time load: read the matching files once
      # Private bucket: IAM role that trusts the service's ClickHouse IAM role.
      # Leave iam_role_arn null for a public bucket.
      authentication = var.iam_role_arn == null ? null : "IAM_ROLE"
      iam_role       = var.iam_role_arn
    }
  }

  destination = {
    database      = "mask_lab"
    table         = "users_landing"
    managed_table = false # the Null table and the MV exist before the pipe starts
    columns       = local.columns
  }

  field_mappings = [
    for c in local.columns : { source_field = c.name, destination_field = c.name }
  ]
}

output "pipe_id" {
  value = clickhouse_clickpipe.users.id
}

output "pipe_state" {
  value = clickhouse_clickpipe.users.state
}
