# deploy.sh writes these into config.env (names are read by the scripts of the next task).

output "aws_region" {
  value = var.aws_region
}

output "bucket" {
  value = aws_s3_bucket.data.bucket
}

output "aurora_cluster_id" {
  value = try(aws_rds_cluster.this[0].id, "")
}

output "aurora_instance_id" {
  value = try(aws_rds_cluster_instance.this[0].id, "")
}

output "aurora_class" {
  value = var.create_aurora ? var.aurora_instance_class : ""
}

output "aurora_host" {
  description = "Cluster (writer) endpoint"
  value       = try(aws_rds_cluster.this[0].endpoint, "")
}

output "aurora_secret_arn" {
  description = "Secrets Manager secret holding the Aurora master password"
  value       = try(aws_rds_cluster.this[0].master_user_secret[0].secret_arn, "")
}

output "pgfront_host" {
  description = "Private IP of the PG front end (reached from the generator)"
  value       = try(aws_instance.pgfront[0].private_ip, "")
}

output "pgfront_password" {
  value     = random_password.pgfront.result
  sensitive = true
}

output "pgfront_instance_id" {
  value = try(aws_instance.pgfront[0].id, "")
}

output "pgfront_public_ip" {
  value = try(aws_instance.pgfront[0].public_ip, "")
}

output "generator_public_ip" {
  value = try(aws_instance.generator[0].public_ip, "")
}

output "chc_s3_role_arn" {
  description = "Role ClickHouse Cloud assumes to read the bucket (empty unless chc_iam_role_arn is set)"
  value       = try(aws_iam_role.chc_s3[0].arn, "")
}

# ---- Glue catalog + Iceberg (empty unless enable_glue = true)

output "glue_parquet_db" {
  value = try(aws_glue_catalog_database.parquet[0].name, "")
}

output "glue_iceberg_db" {
  value = try(aws_glue_catalog_database.iceberg[0].name, "")
}

output "athena_workgroup" {
  value = try(aws_athena_workgroup.this[0].name, "")
}

output "glue_catalog_arn" {
  description = "Catalog ARN for IMPORT FOREIGN SCHEMA ... OPTIONS (location ...)"
  value       = var.enable_glue ? local.glue_catalog_arn : ""
}

output "account_id" {
  value = local.account_id
}
