output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.confluent.id
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip
}

output "instance_private_ip" {
  description = "Private IP address of the EC2 instance"
  value       = aws_instance.confluent.private_ip
}

output "control_center_url" {
  description = "URL for Confluent Control Center"
  value       = "http://${var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip}:9021"
}

output "schema_registry_url" {
  description = "URL for Schema Registry"
  value       = "http://${var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip}:8081"
}

output "kafka_connect_url" {
  description = "URL for Kafka Connect"
  value       = "http://${var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip}:8083"
}

output "ksqldb_url" {
  description = "URL for ksqlDB Server"
  value       = "http://${var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip}:8088"
}

output "rest_proxy_url" {
  description = "URL for REST Proxy"
  value       = "http://${var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip}:8082"
}

output "kafka_bootstrap_servers" {
  description = "Kafka bootstrap servers (external access)"
  value       = "${var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip}:9092"
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = var.key_pair_name != null ? "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip}" : "SSH key pair not configured"
}

output "sample_topic_name" {
  description = "Name of the sample topic created"
  value       = var.sample_topic_name
}

output "kafka_sasl_username" {
  description = "Kafka SASL username (API Key)"
  value       = var.kafka_sasl_username
}

output "kafka_sasl_password" {
  description = "Kafka SASL password (API Secret)"
  value       = var.kafka_sasl_password
  sensitive   = true
}

output "useful_commands" {
  description = "Useful commands to manage Confluent Platform"
  value = var.key_pair_name != null ? join("\n", [
    "# Check status",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip} 'sudo /opt/confluent/status.sh'",
    "",
    "# Stop Confluent Platform",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip} 'sudo /opt/confluent/stop.sh'",
    "",
    "# Start Confluent Platform",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip} 'sudo /opt/confluent/start.sh'",
    "",
    "# View data producer logs",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip} 'sudo journalctl -u confluent-producer -f'"
  ]) : "SSH key pair not configured - SSH access not available"
}
