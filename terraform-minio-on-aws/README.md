# Terraform MinIO on AWS

Terraform scripts to deploy a single-node MinIO server on AWS EC2.

## Prerequisites

1. Terraform installed (>= 1.0)
2. AWS account and credentials configured
3. AWS EC2 Key Pair created

## Features

- **Configurable Instance Type**: Default `c5.xlarge`, customizable
- **EBS Volume Size**: Default `250GB`, customizable
- **AWS Authentication**: Uses standard AWS environment variables
- **Security Group**: Automatically configures MinIO API (9000), Console (9001), and SSH (22) ports
- **Elastic IP**: Optional stable public IP allocation
- **Automated Installation**: MinIO automatically installed and configured via user-data script

## Deployment Instructions

### 1. Configure AWS Credentials and Region

Set up AWS credentials and region using environment variables:

```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
export AWS_SESSION_TOKEN="your-session-token"  # Optional, for temporary credentials
export AWS_REGION="us-west-2"  # Optional, defaults to us-east-1 if not set

# Or use AWS CLI configuration (recommended)
aws configure
```

The AWS region will be determined in this order:
1. `aws_region` variable in terraform.tfvars (if set)
2. `AWS_REGION` or `AWS_DEFAULT_REGION` environment variable
3. Falls back to `us-east-1` if none of the above are set

### 2. Create terraform.tfvars File

```bash
cp terraform.tfvars.example terraform.tfvars
```

### 3. Edit terraform.tfvars File

```hcl
# AWS Configuration
# Optional: Region can be set via AWS_REGION environment variable
# aws_region = "us-west-2"

# EC2 Configuration
instance_name   = "minio-server"
instance_type   = "c5.xlarge"      # Change to desired instance type
ebs_volume_size = 250               # Change to desired EBS size (GB)
key_pair_name   = "YOUR_KEY_PAIR_NAME"

# Network Configuration
allowed_cidr_blocks = ["YOUR_IP/32"]  # Restrict to your IP for better security
use_elastic_ip      = true

# MinIO Configuration
minio_root_user     = "minioadmin"
minio_root_password = "minioadmin123"  # Change to a strong password
minio_data_dir      = "/mnt/data"
```

### 4. Initialize Terraform

```bash
terraform init
```

### 5. Review Execution Plan

```bash
terraform plan
```

### 6. Deploy

```bash
terraform apply
```

After deployment completes, the following information will be displayed:
- MinIO Console URL
- MinIO API Endpoint
- SSH connection command
- Public/Private IP addresses

### 7. Access MinIO

Access the MinIO web console using the `minio_console_url` from the output:
- URL: `http://<PUBLIC_IP>:9001`
- Username: Value set in `minio_root_user` in terraform.tfvars
- Password: Value set in `minio_root_password` in terraform.tfvars

## Configurable Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region for deployment | Uses `AWS_REGION` env var, or `us-east-1` |
| `instance_name` | EC2 instance name tag | `minio-server` |
| `instance_type` | EC2 instance type | `c5.xlarge` |
| `ebs_volume_size` | EBS volume size in GB | `250` |
| `key_pair_name` | EC2 key pair name | - (required) |
| `allowed_cidr_blocks` | CIDR blocks allowed to access | `["0.0.0.0/0"]` |
| `minio_root_user` | MinIO root username | `minioadmin` |
| `minio_root_password` | MinIO root password | `minioadmin` |
| `minio_data_dir` | MinIO data directory path | `/mnt/data` |
| `use_elastic_ip` | Enable Elastic IP allocation | `true` |

## Recommended Instance Types

Recommended instance types based on MinIO usage:

- **Development/Testing**: `t3.medium`, `t3.large`
- **Small Production**: `c5.xlarge` (default), `c5.2xlarge`
- **Medium Production**: `c5.4xlarge`, `c5.9xlarge`
- **Large Production**: `c5.12xlarge`, `c5.18xlarge` or memory-optimized `r5` series

## View Outputs

```bash
# View all outputs
terraform output

# View specific output
terraform output minio_console_url

# View sensitive information (passwords, etc.)
terraform output -json minio_credentials
```

## SSH Access

```bash
ssh -i /path/to/your-key.pem ec2-user@<PUBLIC_IP>

# Check MinIO status
sudo systemctl status minio

# View MinIO logs
sudo journalctl -u minio -f

# Check installation logs
sudo cat /var/log/minio-setup.log
```

## Destroy Resources

```bash
terraform destroy
```

## Security Recommendations

1. **terraform.tfvars Security**:
   - Add `terraform.tfvars` to `.gitignore`
   - Use AWS environment variables instead of hardcoding credentials

2. **Network Security**:
   - Restrict `allowed_cidr_blocks` to your IP address
   - Use VPN or Bastion host for production environments

3. **MinIO Password**:
   - Use strong passwords (minimum 8 characters)
   - Rotate passwords regularly

4. **HTTPS Configuration**:
   - Apply SSL/TLS certificates for production environments
   - Consider using Let's Encrypt or AWS Certificate Manager

## Troubleshooting

### MinIO Service Not Starting

```bash
# SSH into the instance and check status
sudo systemctl status minio
sudo journalctl -u minio -n 50
```

### Check user-data Script Execution Logs

```bash
sudo cat /var/log/cloud-init-output.log
```

### Verify Firewall Configuration

Check that required ports (9000, 9001, 22) are open in the Security Group settings

## AWS Authentication Methods

This configuration supports multiple AWS authentication methods:

1. **Environment Variables** (Recommended):
```bash
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_SESSION_TOKEN="your-session-token"  # Optional, for temporary credentials
export AWS_REGION="us-west-2"  # Optional, defaults to us-east-1
```

2. **AWS CLI Configuration**:
```bash
aws configure
```

3. **IAM Role** (for EC2/ECS deployments):
   - No explicit credentials needed
   - Automatically uses attached IAM role

4. **AWS SSO**:
```bash
aws sso login
```

The Terraform AWS provider will automatically detect and use credentials from these sources.

## License

MIT License
