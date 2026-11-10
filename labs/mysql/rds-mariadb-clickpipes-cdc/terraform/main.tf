variable "organization_id" {}
variable "token_key" { sensitive = true }
variable "token_secret" { sensitive = true }
variable "service_id" {}
variable "mariadb_host" {}
variable "mariadb_password" { sensitive = true }
variable "source_type" { default = "rdsmariadb" }

provider "clickhouse" {
  organization_id = var.organization_id
  token_key       = var.token_key
  token_secret    = var.token_secret
}

resource "clickhouse_clickpipe" "mariadb_cdc" {
  name       = "lab-terraform-${var.source_type}"
  service_id = var.service_id

  source = {
    mysql = {
      type           = var.source_type
      host           = var.mariadb_host
      port           = 3306
      authentication = "basic"
      credentials = {
        username = "clickpipes_user"
        password = var.mariadb_password
      }
      settings = {
        replication_mode = "cdc"
      }
      table_mappings = [{
        source_schema_name = "shop"
        source_table       = "orders"
        target_table       = "orders_tf"
      }]
    }
  }

  destination = {
    database = "mariadb_cdc_lab"
  }
}
