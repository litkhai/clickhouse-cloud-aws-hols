# Migration to Hostname-Based Outputs

## Summary

All Terraform outputs have been migrated from using IP addresses to using AWS EC2 public DNS hostnames for improved reliability and consistency.

## Changes Made

### Date: 2025-11-20

### Modified Files
- [outputs.tf](outputs.tf)

## Key Changes

### 1. Added Public DNS Hostname Output

**New Output** ([outputs.tf:11-14](outputs.tf#L11-L14)):
```hcl
output "instance_public_dns" {
  description = "Public DNS hostname of the EC2 instance"
  value       = aws_instance.confluent.public_dns
}
```

### 2. Updated All Service URLs

All service URLs now use `aws_instance.confluent.public_dns` instead of IP addresses:

- **Control Center**: `http://${aws_instance.confluent.public_dns}:9021`
- **Schema Registry**: `http://${aws_instance.confluent.public_dns}:8081`
- **Kafka Connect**: `http://${aws_instance.confluent.public_dns}:8083`
- **ksqlDB Server**: `http://${aws_instance.confluent.public_dns}:8088`
- **REST Proxy**: `http://${aws_instance.confluent.public_dns}:8082`

### 3. Updated Kafka Bootstrap Servers

**Main Bootstrap Servers** ([outputs.tf:46-48](outputs.tf#L46-L48)):
```hcl
output "kafka_bootstrap_servers" {
  description = "Kafka bootstrap servers (external access with hostname)"
  value       = "${aws_instance.confluent.public_dns}:9092"
}
```

**SASL_SSL (TLS)** - Port 9092 ([outputs.tf:51-54](outputs.tf#L51-L54)):
```hcl
output "kafka_bootstrap_servers_ssl" {
  description = "Kafka bootstrap servers for SASL_SSL (port 9092)"
  value       = "${aws_instance.confluent.public_dns}:9092"
}
```

**SASL_PLAINTEXT** - Port 9093 ([outputs.tf:56-59](outputs.tf#L56-L59)):
```hcl
output "kafka_bootstrap_servers_plaintext" {
  description = "Kafka bootstrap servers for SASL_PLAINTEXT (port 9093)"
  value       = "${aws_instance.confluent.public_dns}:9093"
}
```

### 4. Updated SSH Command

**Before**:
```bash
ssh -i /path/to/key.pem ubuntu@<IP_ADDRESS>
```

**After** ([outputs.tf:61-64](outputs.tf#L61-L64)):
```bash
ssh -i /path/to/key.pem ubuntu@<PUBLIC_DNS_HOSTNAME>
```

### 5. Enhanced Connection Info Output

The `connection_info` output now displays both hostname (primary) and IP (secondary):

```
================================================================================
Confluent Platform with SASL/PLAIN + TLS Authentication
================================================================================

Kafka Bootstrap Servers:
  SASL_SSL (TLS):       <hostname>:9092 [PRIMARY]
  SASL_PLAINTEXT:       <hostname>:9093 [FALLBACK]

Public DNS Hostname:    <hostname>
Public IP Address:      <ip_address>

Authentication:
  SASL Mechanism:    PLAIN
  Username:          admin
  Password:          ***

Service URLs:
  Control Center:    http://<hostname>:9021
  Schema Registry:   http://<hostname>:8081
  Kafka Connect:     http://<hostname>:8083
  ksqlDB Server:     http://<hostname>:8088
  REST Proxy:        http://<hostname>:8082

================================================================================
```

### 6. Updated Useful Commands

All SSH commands in the `useful_commands` output now use hostnames:

```bash
# Check status
ssh -i /path/to/key.pem ubuntu@<hostname> 'sudo /opt/confluent/status.sh'

# Stop Confluent Platform
ssh -i /path/to/key.pem ubuntu@<hostname> 'sudo /opt/confluent/stop.sh'

# Start Confluent Platform
ssh -i /path/to/key.pem ubuntu@<hostname> 'sudo /opt/confluent/start.sh'

# View data producer logs
ssh -i /path/to/key.pem ubuntu@<hostname> 'sudo journalctl -u confluent-producer -f'
```

### 7. Updated Test SASL Connection Instructions

All SCP and SSH commands now use hostnames, including TLS certificate download:

```bash
# Download the Python test script (configured for SASL_PLAINTEXT on port 9093)
scp -i /path/to/key.pem ubuntu@<hostname>:/opt/confluent/test_kafka_sasl.py .

# Install required Python package
pip3 install confluent-kafka

# Run the test (tests SASL_PLAINTEXT on port 9093)
python3 test_kafka_sasl.py

# Or test directly on the EC2 instance
ssh -i /path/to/key.pem ubuntu@<hostname> 'python3 /opt/confluent/test_kafka_sasl.py'

# For SASL_SSL testing (port 9092), first download the TLS certificate:
scp -i /path/to/key.pem ubuntu@<hostname>:/opt/confluent/kafka-broker-cert.crt .
```

## Benefits

### 1. **Reliability**
- AWS public DNS hostnames automatically resolve to the current public IP
- No need to update connection strings when IP addresses change

### 2. **Consistency**
- All outputs use the same hostname format
- Easier to document and share connection information

### 3. **Best Practices**
- Follows AWS recommendations for referencing EC2 instances
- Aligns with how production systems typically configure connections

### 4. **TLS Certificate Compatibility**
- Hostnames work better with TLS certificates
- Avoids certificate hostname mismatch warnings

## Backward Compatibility

The following outputs are **retained** for backward compatibility:

- `instance_public_ip` - Still available if IP address is needed
- All original output names maintained (e.g., `kafka_bootstrap_servers`)

## Usage After Migration

### View All Outputs
```bash
cd terraform-confluent-aws
terraform output
```

### View Specific Outputs
```bash
# Public DNS hostname
terraform output instance_public_dns

# Kafka bootstrap servers (hostname-based)
terraform output kafka_bootstrap_servers

# Complete connection information
terraform output connection_info

# Test connection instructions
terraform output -raw test_sasl_connection
```

### Connect to Kafka
```bash
# Using hostname (recommended)
kafka-console-consumer --bootstrap-server $(terraform output -raw kafka_bootstrap_servers) \
  --consumer.config sasl.properties \
  --topic sample-data-topic \
  --from-beginning
```

### SSH to Instance
```bash
# Copy the exact command from output
terraform output ssh_command
```

## Testing Checklist

After applying these changes, verify:

- [ ] `terraform output` displays all outputs without errors
- [ ] `instance_public_dns` shows valid AWS hostname
- [ ] All service URLs use hostname format
- [ ] SSH command works with hostname
- [ ] Kafka client connections work with hostname-based bootstrap servers
- [ ] Control Center accessible via hostname URL
- [ ] Test script can be downloaded via SCP using hostname

## Related Documentation

- [DEPLOYMENT_SUMMARY.md](DEPLOYMENT_SUMMARY.md) - Overall deployment details
- [SASL_CONNECTION_GUIDE.md](SASL_CONNECTION_GUIDE.md) - Connection examples
- [outputs.tf](outputs.tf) - Complete outputs configuration
- [variables.tf](variables.tf) - Configurable parameters

## Migration Date

**Completed**: November 20, 2025

## Notes

- No changes required to [main.tf](main.tf) or [user-data.sh](user-data.sh)
- TLS certificates already generated with hostname support
- Test scripts dynamically generated with correct hostname at deployment time
- All background services (producer, Control Center, etc.) continue to work unchanged
