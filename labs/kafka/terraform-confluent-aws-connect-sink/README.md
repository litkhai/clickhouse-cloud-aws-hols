# Confluent Platform with ClickHouse Sink Connector on AWS

This Terraform configuration deploys a complete Confluent Platform stack on AWS EC2 with ClickHouse Sink Connector pre-installed, enabling automatic data streaming from Kafka topics to ClickHouse Cloud.

## Features

- **Complete Confluent Platform**: All core components (Kafka, ZooKeeper, Schema Registry, Connect, ksqlDB, Control Center, REST Proxy)
- **ClickHouse Sink Connector**: Pre-installed and ready to stream data to ClickHouse Cloud
- **Automated Setup**: One-command deployment with Docker Compose
- **Sample Data Producer**: Automatically generates sample data to demonstrate the pipeline
- **SASL Authentication**: Production-ready authentication with SASL/PLAIN (like Confluent Cloud)
- **Easy Management**: Scripts for start, stop, and status checking

## Architecture

```
Sample Data Producer → Kafka Topic → ClickHouse Sink Connector → ClickHouse Cloud
                          ↓
                   Control Center (Monitoring)
```

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- AWS Account with appropriate permissions
- AWS CLI configured with credentials
- ClickHouse Cloud account (optional - can be configured later)
- SSH key pair for remote access (optional)

## Quick Start

### 1. Clone and Navigate

```bash
cd terraform-confluent-aws-connect-sink
```

### 2. Configure Variables

Copy the example configuration:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` to customize your deployment:

```hcl
# AWS Configuration
aws_region = "us-east-1"
instance_name = "confluent-clickhouse-demo"
instance_type = "r5.xlarge"
key_pair_name = "my-key-pair"  # Optional: for SSH access

# ClickHouse Cloud Configuration (optional - can be added later)
clickhouse_host     = "your-instance.clickhouse.cloud"
clickhouse_port     = 8443
clickhouse_database = "default"
clickhouse_username = "default"
clickhouse_password = "your-password"
clickhouse_table    = "kafka_events"
clickhouse_use_ssl  = true
```

### 3. Deploy

```bash
# Set AWS credentials
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"

# Initialize Terraform
terraform init

# Review the deployment plan
terraform plan

# Deploy the infrastructure
terraform apply
```

The deployment takes about 10-15 minutes. Terraform will output all important URLs and connection information.

### 4. Access Confluent Control Center

After deployment completes:

```bash
# Get the Control Center URL
terraform output control_center_url
```

Open the URL in your browser to access the Confluent Control Center Web UI, where you can:
- Monitor Kafka topics and messages
- View connector status
- Manage ClickHouse Sink Connector
- Track data flow from Kafka to ClickHouse

## ClickHouse Cloud Setup

### Option 1: Configure During Deployment

Add ClickHouse Cloud credentials to `terraform.tfvars` before running `terraform apply`. The ClickHouse Sink Connector will be automatically created and started.

### Option 2: Configure After Deployment

If you didn't configure ClickHouse during deployment, you can add it later:

1. SSH into the instance:
```bash
ssh -i /path/to/your-key.pem ubuntu@<instance-dns>
```

2. Edit the connector creation script:
```bash
sudo nano /opt/confluent/create-clickhouse-sink.sh
```

3. Update the ClickHouse connection details and run:
```bash
sudo /opt/confluent/create-clickhouse-sink.sh
```

### Create ClickHouse Table

Before the connector can write data, create a table in ClickHouse Cloud:

```sql
CREATE TABLE default.kafka_events
(
    event_id UInt64,
    timestamp DateTime64(3),
    user_id UInt32,
    event_type String,
    value UInt32,
    metadata Tuple(source String, version String)
)
ENGINE = MergeTree()
ORDER BY (timestamp, event_id);
```

## Connector Management

### Check Connector Status

```bash
# Get the status command from Terraform outputs
terraform output clickhouse_connector_status

# Or directly
curl http://<instance-dns>:8083/connectors/clickhouse-sink-connector/status | jq '.'
```

### List All Connectors

```bash
curl http://<instance-dns>:8083/connectors | jq '.'
```

### View Connector Configuration

```bash
curl http://<instance-dns>:8083/connectors/clickhouse-sink-connector | jq '.'
```

### Delete and Recreate Connector

```bash
# Delete
curl -X DELETE http://<instance-dns>:8083/connectors/clickhouse-sink-connector

# Recreate
ssh -i /path/to/your-key.pem ubuntu@<instance-dns> 'sudo /opt/confluent/create-clickhouse-sink.sh'
```

## Monitoring Data Flow

### 1. Watch Kafka Producer Logs

```bash
ssh -i /path/to/your-key.pem ubuntu@<instance-dns> 'sudo journalctl -u confluent-producer -f'
```

### 2. Check Kafka Topic Messages

```bash
# From the EC2 instance
docker exec broker kafka-console-consumer \
  --bootstrap-server localhost:29092 \
  --topic sample-data-topic \
  --from-beginning
```

### 3. Verify Data in ClickHouse Cloud

```sql
-- Check record count
SELECT count() FROM default.kafka_events;

-- View recent events
SELECT * FROM default.kafka_events ORDER BY timestamp DESC LIMIT 10;

-- Analyze by event type
SELECT event_type, count() as count FROM default.kafka_events GROUP BY event_type;
```

## Sample Data Format

The data producer generates JSON messages with this structure:

```json
{
  "event_id": 1,
  "timestamp": "2025-01-15T10:30:00Z",
  "user_id": 123,
  "event_type": "page_view",
  "value": 456,
  "metadata": {
    "source": "web",
    "version": "1.0"
  }
}
```

Event types include: `page_view`, `click`, `purchase`, `signup`, `logout`

## Configuration

### Terraform Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `aws_region` | AWS region for deployment | null (uses env var) | No |
| `instance_name` | Name tag for EC2 instance | "confluent-server" | No |
| `instance_type` | EC2 instance type | "r5.xlarge" | No |
| `key_pair_name` | SSH key pair name | null | No |
| `clickhouse_host` | ClickHouse Cloud host | null | No |
| `clickhouse_port` | ClickHouse Cloud port | 8443 | No |
| `clickhouse_database` | ClickHouse database | "default" | No |
| `clickhouse_username` | ClickHouse username | "default" | No |
| `clickhouse_password` | ClickHouse password | null | No |
| `clickhouse_table` | Target table name | "kafka_events" | No |
| `clickhouse_use_ssl` | Use SSL for ClickHouse | true | No |

### Instance Type Recommendations

- **Development**: `t3.xlarge` (4 vCPU, 16 GB RAM)
- **Testing**: `r5.xlarge` (4 vCPU, 32 GB RAM) - **Default**
- **Production**: `r5.2xlarge` or larger (8+ vCPU, 64+ GB RAM)

## Service Endpoints

After deployment, access these services:

| Service | Port | Description |
|---------|------|-------------|
| Control Center | 9021 | Web UI for management |
| Kafka Connect | 8083 | Connector management API |
| Schema Registry | 8081 | Schema management |
| ksqlDB Server | 8088 | Stream processing |
| Kafka Broker (SASL_SSL) | 9092 | Secure Kafka access |
| Kafka Broker (SASL_PLAINTEXT) | 9093 | Kafka access (fallback) |

## Kafka Authentication

The deployment uses SASL/PLAIN authentication (like Confluent Cloud):

```bash
# Get credentials
terraform output kafka_sasl_username
terraform output -raw kafka_sasl_password
```

Default credentials:
- **Username**: `admin`
- **Password**: `admin-secret`

## Management Scripts

Once SSH connected, use these scripts:

```bash
# Check status of all services
sudo /opt/confluent/status.sh

# Stop Confluent Platform
sudo /opt/confluent/stop.sh

# Start Confluent Platform
sudo /opt/confluent/start.sh

# Create/recreate ClickHouse Sink Connector
sudo /opt/confluent/create-clickhouse-sink.sh
```

## Troubleshooting

### Connector Not Creating

1. Check Kafka Connect logs:
```bash
docker logs connect -f
```

2. Verify ClickHouse connectivity:
```bash
# From the EC2 instance
curl -v https://<clickhouse-host>:8443/
```

3. Check connector plugins:
```bash
curl http://localhost:8083/connector-plugins | jq '.'
```

### No Data Flowing to ClickHouse

1. Check connector status:
```bash
curl http://localhost:8083/connectors/clickhouse-sink-connector/status | jq '.'
```

2. Look for errors in connector tasks:
```bash
curl http://localhost:8083/connectors/clickhouse-sink-connector/status | jq '.tasks[].trace'
```

3. Verify the ClickHouse table exists and schema matches

4. Check Kafka topic has data:
```bash
docker exec broker kafka-console-consumer \
  --bootstrap-server localhost:29092 \
  --topic sample-data-topic \
  --max-messages 10
```

### Connector Shows FAILED Status

Common issues:
- **Authentication failed**: Check ClickHouse username/password
- **Table not found**: Create the table in ClickHouse
- **Network issues**: Verify security groups allow outbound HTTPS
- **SSL/TLS errors**: Ensure `clickhouse_use_ssl` matches your ClickHouse setup

View detailed error:
```bash
curl http://localhost:8083/connectors/clickhouse-sink-connector/status | jq '.tasks[0].trace'
```

## Demo Walkthrough

### Complete End-to-End Test

1. **Deploy the infrastructure**:
```bash
terraform apply
```

2. **Access Control Center**:
```bash
open $(terraform output -raw control_center_url)
```

3. **Verify Kafka topic exists**:
   - Navigate to "Topics" in Control Center
   - Find `sample-data-topic`
   - View messages flowing in

4. **Check connector status**:
   - Navigate to "Connect" → "connect-default"
   - View `clickhouse-sink-connector`
   - Verify status is "Running"

5. **Query ClickHouse Cloud**:
```sql
SELECT count() FROM default.kafka_events;
SELECT event_type, count(*) FROM default.kafka_events GROUP BY event_type;
```

6. **Watch real-time data flow**:
```bash
# Terminal 1: Watch Kafka producer
ssh -i key.pem ubuntu@<dns> 'sudo journalctl -u confluent-producer -f'

# Terminal 2: Query ClickHouse every few seconds
watch -n 5 "clickhouse-client --host <host> --query 'SELECT count() FROM default.kafka_events'"
```

## Cost Considerations

Estimated AWS costs (us-east-1 region):

- **r5.xlarge instance**: ~$0.25/hour (~$180/month)
- **EBS gp3 volume (100 GB)**: ~$8/month
- **Data transfer**: Variable based on usage
- **Total estimated cost**: ~$190-200/month for 24/7 operation

### Cost Optimization

1. **Stop when not in use**: `terraform destroy` when done
2. **Use smaller instance**: Change to `t3.xlarge` for development
3. **Reduce EBS volume**: Adjust `ebs_volume_size` if less storage needed

## Security Best Practices

### For Production Use

1. **Restrict CIDR blocks**: Limit `allowed_cidr_blocks` to your IP ranges
2. **Use strong passwords**: Change default `kafka_sasl_password` and `clickhouse_password`
3. **Enable CloudWatch**: Add monitoring and alerting
4. **Use private subnets**: Deploy in private subnet with bastion host
5. **Secrets management**: Store credentials in AWS Secrets Manager
6. **Regular updates**: Keep Confluent Platform version updated

### Current Security Posture

⚠️ **Warning**: Default configuration is for development/testing only

- All ports open to `0.0.0.0/0`
- Default SASL credentials
- Public IP with direct access

## Outputs

After deployment, Terraform provides:

- `control_center_url`: Control Center web UI URL
- `kafka_connect_url`: Kafka Connect API URL
- `kafka_bootstrap_servers`: Kafka bootstrap servers
- `clickhouse_host`: Configured ClickHouse host
- `clickhouse_connector_status`: Command to check connector status
- `clickhouse_connector_commands`: Useful connector management commands

View all outputs:
```bash
terraform output
```

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

This will:
- Terminate the EC2 instance
- Delete the security group
- Remove all associated resources

**Note**: This is irreversible and will delete all data on the instance.

## Advanced Configuration

### Custom Connector Configuration

Edit `/opt/confluent/create-clickhouse-sink.sh` on the EC2 instance to customize:

- Batch size
- Flush interval
- Error handling
- Data transformation
- Multiple topics

Example custom configuration:

```json
{
  "name": "clickhouse-sink-connector",
  "config": {
    "connector.class": "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
    "tasks.max": "2",
    "topics": "sample-data-topic,another-topic",
    "hostname": "your-instance.clickhouse.cloud",
    "port": "8443",
    "database": "default",
    "batch.size": "10000",
    "buffer.flush.time": "1000"
  }
}
```

### Multiple Connectors

Create additional connectors for different topics:

```bash
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d '{
    "name": "another-clickhouse-sink",
    "config": {
      "connector.class": "com.clickhouse.kafka.connect.ClickHouseSinkConnector",
      "topics": "another-topic",
      ...
    }
  }'
```

## Related Projects

- [terraform-confluent-aws](../terraform-confluent-aws): Base Confluent Platform without ClickHouse
- [ClickHouse Cloud](https://clickhouse.com/cloud): Managed ClickHouse service

## Support

For issues or questions:

- Confluent Documentation: https://docs.confluent.io/
- ClickHouse Documentation: https://clickhouse.com/docs
- ClickHouse Kafka Connect: https://github.com/ClickHouse/clickhouse-kafka-connect

## License

This configuration is provided as-is for educational and development purposes.
