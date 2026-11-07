output "region" {
  value = var.aws_region
}

output "instance_id" {
  value = aws_instance.client.id
}

output "client_public_ip" {
  description = "Add this address to the ClickHouse Cloud service's IP access list"
  value       = aws_instance.client.public_ip
}

output "valkey_endpoint" {
  value = aws_elasticache_replication_group.valkey.primary_endpoint_address
}

output "bucket" {
  value = aws_s3_bucket.artifacts.bucket
}

output "ddb_kv_table" {
  value = aws_dynamodb_table.kv.name
}

output "ddb_aside_table" {
  value = aws_dynamodb_table.aside.name
}
