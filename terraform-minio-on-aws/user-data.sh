#!/bin/bash

# Setup logging
exec > >(tee -a /var/log/minio-setup.log)
exec 2>&1

echo "=========================================="
echo "MinIO Installation Script (Ubuntu)"
echo "Started at: $(date)"
echo "=========================================="

# Exit on error but log the error
set -e
trap 'echo "ERROR: Script failed at line $LINENO with exit code $?" >&2' ERR

# Update system packages
echo "[1/10] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y || { echo "ERROR: Failed to update package list"; exit 1; }
apt-get upgrade -y || { echo "ERROR: Failed to upgrade system packages"; exit 1; }

# Install required packages
echo "[2/10] Installing required packages..."
apt-get install -y \
    wget \
    curl \
    tar \
    gzip \
    systemd \
    procps \
    net-tools \
    dnsutils \
    ca-certificates \
    || { echo "ERROR: Failed to install required packages"; exit 1; }

# Verify critical commands are available
echo "[3/10] Verifying installed commands..."
for cmd in wget curl systemctl useradd; do
    if ! command -v $cmd &> /dev/null; then
        echo "ERROR: Required command '$cmd' is not available"
        exit 1
    fi
    echo "  ✓ $cmd is available"
done

# Create MinIO user
echo "[4/10] Creating MinIO user..."
if id "minio-user" &>/dev/null; then
    echo "  ℹ User minio-user already exists"
else
    useradd -r minio-user -s /sbin/nologin || { echo "ERROR: Failed to create minio-user"; exit 1; }
    echo "  ✓ User minio-user created"
fi

# Create data directory
echo "[5/10] Creating data directory..."
mkdir -p ${data_dir} || { echo "ERROR: Failed to create data directory"; exit 1; }
chown minio-user:minio-user ${data_dir} || { echo "ERROR: Failed to set ownership"; exit 1; }
chmod 750 ${data_dir}
echo "  ✓ Data directory created at ${data_dir}"

# Download and install MinIO
echo "[6/10] Downloading and installing MinIO server..."
cd /usr/local/bin
if [ -f "minio" ]; then
    echo "  ℹ MinIO binary already exists, removing old version..."
    rm -f minio
fi
wget -q --show-progress https://dl.min.io/server/minio/release/linux-amd64/minio || { echo "ERROR: Failed to download MinIO"; exit 1; }
chmod +x minio
chown minio-user:minio-user minio
echo "  ✓ MinIO server installed successfully"

# Verify MinIO binary
/usr/local/bin/minio --version || { echo "ERROR: MinIO binary verification failed"; exit 1; }
echo "  ✓ MinIO binary verified"

# Create MinIO environment file
echo "[7/10] Creating MinIO environment configuration..."

# Validate credentials length
USER_LENGTH=$${#minio_root_user}
PASS_LENGTH=$${#minio_root_password}

if [ $USER_LENGTH -lt 3 ]; then
    echo "ERROR: MINIO_ROOT_USER must be at least 3 characters (current: $USER_LENGTH)"
    exit 1
fi

if [ $PASS_LENGTH -lt 8 ]; then
    echo "ERROR: MINIO_ROOT_PASSWORD must be at least 8 characters (current: $PASS_LENGTH)"
    exit 1
fi

cat > /etc/default/minio <<EOF
# MinIO local volumes
MINIO_VOLUMES="${data_dir}"

# MinIO Root credentials
MINIO_ROOT_USER=${minio_root_user}
MINIO_ROOT_PASSWORD=${minio_root_password}

# MinIO options
MINIO_OPTS="--console-address :9001"
EOF
chmod 640 /etc/default/minio
chown root:minio-user /etc/default/minio
echo "  ✓ MinIO environment file created"

# Create MinIO systemd service
echo "[8/10] Creating MinIO systemd service..."
cat > /etc/systemd/system/minio.service <<'EOF'
[Unit]
Description=MinIO
Documentation=https://docs.min.io
Wants=network-online.target
After=network-online.target
AssertFileIsExecutable=/usr/local/bin/minio

[Service]
WorkingDirectory=/usr/local

User=minio-user
Group=minio-user
ProtectProc=invisible

EnvironmentFile=/etc/default/minio
ExecStartPre=/bin/bash -c "if [ -z \"$${MINIO_VOLUMES}\" ]; then echo \"Variable MINIO_VOLUMES not set in /etc/default/minio\"; exit 1; fi"
ExecStart=/usr/local/bin/minio server $MINIO_OPTS $MINIO_VOLUMES

# Let systemd restart this service always
Restart=always

# Specifies the maximum file descriptor number that can be opened by this process
LimitNOFILE=65536

# Specifies the maximum number of threads this process can create
TasksMax=infinity

# Disable timeout logic and wait until process is stopped
TimeoutStopSec=infinity
SendSIGKILL=no

[Install]
WantedBy=multi-user.target
EOF
echo "  ✓ MinIO systemd service file created"

# Reload systemd, enable and start MinIO
echo "[9/10] Starting MinIO service..."
systemctl daemon-reload || { echo "ERROR: Failed to reload systemd"; exit 1; }
systemctl enable minio || { echo "ERROR: Failed to enable MinIO service"; exit 1; }
systemctl start minio || { echo "ERROR: Failed to start MinIO service"; exit 1; }
echo "  ✓ MinIO service enabled and started"

# Wait for MinIO to be ready with health check
echo "[10/10] Waiting for MinIO to be ready..."
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if systemctl is-active --quiet minio; then
        if curl -s http://localhost:9000/minio/health/live > /dev/null 2>&1; then
            echo "  ✓ MinIO is healthy and ready"
            break
        fi
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "ERROR: MinIO failed to become healthy after $MAX_RETRIES attempts"
        echo "Service status:"
        systemctl status minio --no-pager
        exit 1
    fi
    echo "  ⏳ Waiting for MinIO to be ready... (attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 2
done

# Install MinIO Client (mc)
echo ""
echo "Installing MinIO Client (mc)..."
cd /usr/local/bin
wget -q --show-progress https://dl.min.io/client/mc/release/linux-amd64/mc || { echo "WARNING: Failed to download MinIO Client"; }
if [ -f "mc" ]; then
    chmod +x mc
    echo "  ✓ MinIO Client installed successfully"
else
    echo "  ⚠ MinIO Client installation failed (non-critical)"
fi

# Get instance metadata
echo ""
echo "Retrieving instance metadata..."
PUBLIC_IP=$(curl -s --connect-timeout 5 http://169.254.169.254/latest/meta-data/public-ipv4 || echo "unavailable")
PRIVATE_IP=$(curl -s --connect-timeout 5 http://169.254.169.254/latest/meta-data/local-ipv4 || echo "unavailable")
INSTANCE_ID=$(curl -s --connect-timeout 5 http://169.254.169.254/latest/meta-data/instance-id || echo "unavailable")

# Create detailed installation summary
echo ""
echo "=========================================="
echo "MinIO Installation Completed Successfully"
echo "=========================================="
echo "Completed at: $(date)"
echo ""
echo "Instance Information:"
echo "  Instance ID: $INSTANCE_ID"
echo "  Public IP:   $PUBLIC_IP"
echo "  Private IP:  $PRIVATE_IP"
echo ""
echo "MinIO Access Information:"
echo "  Console URL: http://$PUBLIC_IP:9001"
echo "  API Endpoint: http://$PUBLIC_IP:9000"
echo "  Username: ${minio_root_user}"
echo "  Password: ${minio_root_password}"
echo ""
echo "Service Status:"
systemctl status minio --no-pager | head -5
echo ""
echo "Data Directory: ${data_dir}"
echo "Configuration: /etc/default/minio"
echo "Service File: /etc/systemd/system/minio.service"
echo "Installation Log: /var/log/minio-setup.log"
echo ""
echo "To view logs:"
echo "  sudo journalctl -u minio -f"
echo "  sudo cat /var/log/minio-setup.log"
echo "=========================================="

# Create completion marker file
cat > /var/log/minio-installation-complete <<EOF
MinIO installation completed successfully at $(date)

Instance ID: $INSTANCE_ID
Public IP: $PUBLIC_IP
Private IP: $PRIVATE_IP

MinIO Console: http://$PUBLIC_IP:9001
MinIO API: http://$PUBLIC_IP:9000
Username: ${minio_root_user}
Password: ${minio_root_password}

Data Directory: ${data_dir}
Configuration: /etc/default/minio
Service File: /etc/systemd/system/minio.service
EOF

echo ""
echo "✓ MinIO installation script completed successfully"
exit 0
