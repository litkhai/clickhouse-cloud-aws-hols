# Confluent Platform on AWS with Terraform

This Terraform configuration deploys a complete Confluent Platform stack on AWS EC2, including Kafka, Schema Registry, Kafka Connect, ksqlDB, Control Center, and REST Proxy.

## Features

- **Complete Confluent Platform**: All core components (Kafka, ZooKeeper, Schema Registry, Connect, ksqlDB, Control Center, REST Proxy)
- **Automated Setup**: One-command deployment with Docker Compose
- **Sample Data Producer**: Automatically generates sample data to a Kafka topic
- **Production-Ready**: Configurable instance types, EBS volumes, and security groups
- **Easy Management**: Scripts for start, stop, and status checking

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- AWS Account with appropriate permissions
- AWS CLI configured with credentials
- (Optional) SSH key pair for remote access

## AWS Credentials Setup

Set your AWS credentials as environment variables:

```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
export AWS_SESSION_TOKEN="your-session-token"  # If using temporary credentials
export AWS_REGION="us-east-1"  # Optional: Set default region
```

## Quick Start

### 1. Clone and Navigate

```bash
cd terraform-confluent-aws
```

### 2. Configure Variables

Copy the example configuration:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` to customize your deployment:

```hcl
aws_region = "us-east-1"
instance_name = "my-confluent-server"
instance_type = "r5.xlarge"
key_pair_name = "my-key-pair"  # Optional: for SSH access
use_elastic_ip = false
```

### 3. Deploy

```bash
# Initialize Terraform
terraform init

# Review the deployment plan
terraform plan

# Deploy the infrastructure
terraform apply
```

The deployment takes about 5-10 minutes. Terraform will output all important URLs and connection information.

### 4. Access Confluent Platform

After deployment completes, access the Control Center:

```bash
# Get the Control Center URL from outputs
terraform output control_center_url
```

Open the URL in your browser to access the Confluent Control Center Web UI.

## Architecture

### Components Deployed

1. **EC2 Instance**: Ubuntu 22.04 LTS with Docker
2. **ZooKeeper**: Cluster coordination (port 2181)
3. **Kafka Broker**: Message streaming (ports 9092, 9093)
4. **Schema Registry**: Schema management (port 8081)
5. **Kafka Connect**: Data integration (port 8083)
6. **ksqlDB**: Stream processing (port 8088)
7. **Control Center**: Web UI for management (port 9021)
8. **REST Proxy**: HTTP REST API (port 8082)
9. **Data Producer**: Systemd service generating sample data

### Network Configuration

The deployment creates a security group with the following ingress rules:

| Port | Service | Description |
|------|---------|-------------|
| 2181 | ZooKeeper | Cluster coordination |
| 9092 | Kafka | Internal broker access |
| 9093 | Kafka | External broker access |
| 8081 | Schema Registry | Schema management API |
| 8083 | Kafka Connect | Connect API |
| 8088 | ksqlDB | ksqlDB API |
| 8082 | REST Proxy | Kafka REST API |
| 9021 | Control Center | Web UI |
| 22 | SSH | Remote access (if key configured) |

## Configuration

### Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `aws_region` | AWS region for deployment | null (uses env var) | No |
| `instance_name` | Name tag for EC2 instance | "confluent-server" | No |
| `instance_type` | EC2 instance type | "r5.xlarge" | No |
| `ebs_volume_size` | EBS volume size in GB | 100 | No |
| `key_pair_name` | SSH key pair name | null | No |
| `allowed_cidr_blocks` | CIDR blocks for access | ["0.0.0.0/0"] | No |
| `use_elastic_ip` | Allocate Elastic IP | false | No |
| `confluent_version` | Confluent Platform version | "7.5.0" | No |
| `sample_topic_name` | Sample topic name | "sample-data-topic" | No |
| `data_producer_interval` | Data production interval (seconds) | 5 | No |

### Instance Type Recommendations

- **Development**: `t3.xlarge` (4 vCPU, 16 GB RAM)
- **Testing**: `r5.xlarge` (4 vCPU, 32 GB RAM) - **Default**
- **Production**: `r5.2xlarge` or larger (8+ vCPU, 64+ GB RAM)

## Management

### SSH Access

If you configured a key pair:

```bash
# Get SSH command from outputs
terraform output ssh_command

# Or manually connect
ssh -i ~/.ssh/your-key.pem ubuntu@<instance-ip>
```

### Management Scripts

Once connected via SSH, use these scripts:

```bash
# Check status of all services
sudo /opt/confluent/status.sh

# Stop Confluent Platform
sudo /opt/confluent/stop.sh

# Start Confluent Platform
sudo /opt/confluent/start.sh

# View data producer logs
sudo journalctl -u confluent-producer -f
```

### Using Kafka

#### List Topics

```bash
docker exec broker kafka-topics --list --bootstrap-server localhost:9092
```

#### Consume Messages

```bash
docker exec broker kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic sample-data-topic \
  --from-beginning
```

#### Produce Messages

```bash
docker exec -i broker kafka-console-producer \
  --broker-list localhost:9092 \
  --topic sample-data-topic
```

### Connecting from External Applications

Use the external bootstrap server for remote connections:

```bash
# Get bootstrap servers
terraform output kafka_bootstrap_servers

# Example: <public-ip>:9093
```

## Sample Data Format

The data producer generates JSON messages with the following structure:

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

## Monitoring

### Control Center

Access the Confluent Control Center at port 9021:

- View cluster health
- Monitor topics and consumers
- Manage connectors
- Execute ksqlDB queries
- View metrics and alerts

### Docker Compose

```bash
# View all container status
docker compose ps

# View specific container logs
docker logs broker -f
docker logs control-center -f

# View resource usage
docker stats
```

## Outputs

After deployment, Terraform provides:

- `instance_id`: EC2 instance ID
- `instance_public_ip`: Public IP address
- `control_center_url`: Control Center web UI URL
- `schema_registry_url`: Schema Registry API URL
- `kafka_connect_url`: Kafka Connect API URL
- `ksqldb_url`: ksqlDB Server API URL
- `rest_proxy_url`: REST Proxy API URL
- `kafka_bootstrap_servers`: Kafka bootstrap servers for external connections
- `ssh_command`: SSH connection command
- `useful_commands`: Quick reference commands

## Troubleshooting

### Services Not Starting

Check Docker container status:

```bash
docker compose ps
docker compose logs
```

### Cannot Access Control Center

1. Verify security group allows access from your IP
2. Check if Docker containers are running
3. Wait 2-3 minutes after deployment for services to fully start

### Data Producer Not Running

```bash
# Check service status
sudo systemctl status confluent-producer

# Restart service
sudo systemctl restart confluent-producer

# View logs
sudo journalctl -u confluent-producer -f
```

### Kafka Connection Issues

Verify the external listener is properly configured:

```bash
docker exec broker kafka-broker-api-versions --bootstrap-server localhost:9092
```

## Cost Considerations

Estimated AWS costs (us-east-1 region):

- **r5.xlarge instance**: ~$0.25/hour (~$180/month)
- **EBS gp3 volume (100 GB)**: ~$8/month
- **Data transfer**: Variable based on usage
- **Elastic IP** (if enabled): $0.005/hour when instance stopped

**Total estimated cost**: ~$190-200/month for 24/7 operation

### Cost Optimization

1. **Stop when not in use**: `terraform destroy` when done
2. **Use smaller instance**: Change to `t3.xlarge` for development
3. **Reduce EBS volume**: Adjust `ebs_volume_size` if less storage needed
4. **Disable Elastic IP**: Set `use_elastic_ip = false`

## Security Best Practices

### For Production Use

1. **Restrict CIDR blocks**: Limit `allowed_cidr_blocks` to your IP ranges
2. **Enable encryption**: Add SSL/TLS for Kafka listeners
3. **Enable authentication**: Configure SASL for Kafka
4. **Use private subnets**: Deploy in private subnet with bastion host
5. **Enable CloudWatch**: Add monitoring and alerting
6. **Backup data**: Configure EBS snapshots
7. **Use secrets manager**: Store credentials in AWS Secrets Manager

### Current Security Posture

⚠️ **Warning**: Default configuration is for development/testing only

- All ports open to `0.0.0.0/0`
- No authentication enabled
- No encryption in transit
- Public IP with direct access

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

This will:
- Terminate the EC2 instance
- Delete the security group
- Release the Elastic IP (if allocated)
- Remove all associated resources

**Note**: This is irreversible and will delete all data on the instance.

## Integration with ClickHouse

This Confluent Platform deployment can be integrated with ClickHouse using Kafka Connect:

1. Access the Connect API:
```bash
terraform output kafka_connect_url
```

2. Install the ClickHouse Sink Connector (if not already included)

3. Configure the connector to stream data from Kafka topics to ClickHouse tables

See the main repository for ClickHouse integration examples.

## Support

For issues or questions:

- Confluent Documentation: https://docs.confluent.io/
- Terraform AWS Provider: https://registry.terraform.io/providers/hashicorp/aws/
- Apache Kafka Documentation: https://kafka.apache.org/documentation/

## License

This configuration is provided as-is for educational and development purposes.
