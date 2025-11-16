output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.minio.id
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = var.use_elastic_ip ? aws_eip.minio_eip[0].public_ip : aws_instance.minio.public_ip
}

output "instance_private_ip" {
  description = "Private IP address of the EC2 instance"
  value       = aws_instance.minio.private_ip
}

output "minio_console_url" {
  description = "URL for MinIO web console"
  value       = "http://${var.use_elastic_ip ? aws_eip.minio_eip[0].public_ip : aws_instance.minio.public_ip}:9001"
}

output "minio_api_endpoint" {
  description = "MinIO API endpoint"
  value       = "http://${var.use_elastic_ip ? aws_eip.minio_eip[0].public_ip : aws_instance.minio.public_ip}:9000"
}

output "ssh_connection_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i /path/to/${var.key_pair_name}.pem ec2-user@${var.use_elastic_ip ? aws_eip.minio_eip[0].public_ip : aws_instance.minio.public_ip}"
}

output "minio_credentials" {
  description = "MinIO root credentials"
  value = {
    username = var.minio_root_user
    password = var.minio_root_password
  }
  sensitive = true
}
