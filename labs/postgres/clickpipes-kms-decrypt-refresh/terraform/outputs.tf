output "pg_host" { value = aws_rds_cluster.this.endpoint }
output "pg_user" { value = aws_rds_cluster.this.master_username }
output "pg_database" { value = aws_rds_cluster.this.database_name }
output "kms_key_arn" { value = aws_kms_key.app.arn }
output "kms_alias" { value = aws_kms_alias.app.name }

output "pg_password" {
  value     = random_password.master.result
  sensitive = true
}

output "udf_access_key_id" {
  value     = try(aws_iam_access_key.udf[0].id, "")
  sensitive = true
}

output "udf_secret_access_key" {
  value     = try(aws_iam_access_key.udf[0].secret, "")
  sensitive = true
}

output "udf_role_arn" { value = try(aws_iam_role.udf[0].arn, "") }
