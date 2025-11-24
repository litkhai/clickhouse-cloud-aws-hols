output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.confluent.id
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip
}

output "instance_public_dns" {
  description = "Public DNS hostname of the EC2 instance"
  value       = aws_instance.confluent.public_dns
}

output "instance_private_ip" {
  description = "Private IP address of the EC2 instance"
  value       = aws_instance.confluent.private_ip
}

output "control_center_url" {
  description = "URL for Confluent Control Center"
  value       = "http://${aws_instance.confluent.public_dns}:9021"
}

output "schema_registry_url" {
  description = "URL for Schema Registry"
  value       = "http://${aws_instance.confluent.public_dns}:8081"
}

output "kafka_connect_url" {
  description = "URL for Kafka Connect"
  value       = "http://${aws_instance.confluent.public_dns}:8083"
}

output "ksqldb_url" {
  description = "URL for ksqlDB Server"
  value       = "http://${aws_instance.confluent.public_dns}:8088"
}

output "rest_proxy_url" {
  description = "URL for REST Proxy"
  value       = "http://${aws_instance.confluent.public_dns}:8082"
}

output "kafka_bootstrap_servers" {
  description = "Kafka bootstrap servers (external access with hostname)"
  value       = "${aws_instance.confluent.public_dns}:9092"
}

output "kafka_bootstrap_servers_ssl" {
  description = "Kafka bootstrap servers for SASL_SSL (port 9092)"
  value       = "${aws_instance.confluent.public_dns}:9092"
}

output "kafka_bootstrap_servers_plaintext" {
  description = "Kafka bootstrap servers for SASL_PLAINTEXT (port 9093)"
  value       = "${aws_instance.confluent.public_dns}:9093"
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = var.key_pair_name != null ? "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns}" : "SSH key pair not configured"
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

output "connection_info" {
  description = "Complete connection information"
  sensitive   = true
  value       = <<-EOT
    ================================================================================
    Confluent Platform with SASL/PLAIN + TLS Authentication
    ================================================================================

    Kafka Bootstrap Servers:
      SASL_SSL (TLS):       ${aws_instance.confluent.public_dns}:9092 [PRIMARY]
      SASL_PLAINTEXT:       ${aws_instance.confluent.public_dns}:9093 [FALLBACK]

    Public DNS Hostname:    ${aws_instance.confluent.public_dns}
    Public IP Address:      ${var.use_elastic_ip ? aws_eip.confluent_eip[0].public_ip : aws_instance.confluent.public_ip}

    Authentication:
      SASL Mechanism:    PLAIN
      Username:          ${var.kafka_sasl_username}
      Password:          ${var.kafka_sasl_password}

    Service URLs:
      Control Center:    http://${aws_instance.confluent.public_dns}:9021
      Schema Registry:   http://${aws_instance.confluent.public_dns}:8081
      Kafka Connect:     http://${aws_instance.confluent.public_dns}:8083
      ksqlDB Server:     http://${aws_instance.confluent.public_dns}:8088
      REST Proxy:        http://${aws_instance.confluent.public_dns}:8082

    ================================================================================
  EOT
}

output "useful_commands" {
  description = "Useful commands to manage Confluent Platform"
  value = var.key_pair_name != null ? join("\n", [
    "# Check status",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns} 'sudo /opt/confluent/status.sh'",
    "",
    "# Stop Confluent Platform",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns} 'sudo /opt/confluent/stop.sh'",
    "",
    "# Start Confluent Platform",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns} 'sudo /opt/confluent/start.sh'",
    "",
    "# View data producer logs",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns} 'sudo journalctl -u confluent-producer -f'"
  ]) : "SSH key pair not configured - SSH access not available"
}

output "test_sasl_connection" {
  description = "Instructions to test SASL connection from external client"
  value = var.key_pair_name != null ? join("\n", [
    "# Download the Python test script (configured for SASL_PLAINTEXT on port 9093)",
    "scp -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns}:/opt/confluent/test_kafka_sasl.py .",
    "",
    "# Install required Python package",
    "pip3 install confluent-kafka",
    "",
    "# Run the test (tests SASL_PLAINTEXT on port 9093)",
    "python3 test_kafka_sasl.py",
    "",
    "# Or test directly on the EC2 instance",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns} 'python3 /opt/confluent/test_kafka_sasl.py'",
    "",
    "# For SASL_SSL testing (port 9092), first download the TLS certificate:",
    "scp -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns}:/opt/confluent/kafka-broker-cert.crt ."
  ]) : "SSH key pair not configured - cannot retrieve test script"
}

# ClickHouse Connector Outputs
output "clickhouse_host" {
  description = "ClickHouse Cloud host"
  value       = var.clickhouse_host
}

output "clickhouse_database" {
  description = "ClickHouse database name"
  value       = var.clickhouse_database
}

output "clickhouse_table" {
  description = "ClickHouse table name"
  value       = var.clickhouse_table
}

output "clickhouse_connector_status" {
  description = "Command to check ClickHouse Sink Connector status"
  value       = "curl http://${aws_instance.confluent.public_dns}:8083/connectors/clickhouse-sink-connector/status | jq '.'"
}

output "clickhouse_connector_commands" {
  description = "Useful commands for ClickHouse Sink Connector"
  value = var.key_pair_name != null ? join("\n", [
    "# Check connector status",
    "curl http://${aws_instance.confluent.public_dns}:8083/connectors/clickhouse-sink-connector/status | jq '.'",
    "",
    "# List all connectors",
    "curl http://${aws_instance.confluent.public_dns}:8083/connectors | jq '.'",
    "",
    "# Delete connector (if needed)",
    "curl -X DELETE http://${aws_instance.confluent.public_dns}:8083/connectors/clickhouse-sink-connector",
    "",
    "# Recreate connector (if not configured during deployment)",
    "ssh -i /path/to/${var.key_pair_name}.pem ubuntu@${aws_instance.confluent.public_dns} 'sudo /opt/confluent/create-clickhouse-sink.sh'"
  ]) : "SSH key pair not configured"
}
