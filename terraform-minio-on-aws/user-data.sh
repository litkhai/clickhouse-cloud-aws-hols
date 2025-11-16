#!/bin/bash
set -e

# Update system packages
dnf update -y

# Install required packages
dnf install -y wget curl

# Create MinIO user
useradd -r minio-user -s /sbin/nologin

# Create data directory
mkdir -p ${data_dir}
chown minio-user:minio-user ${data_dir}

# Download and install MinIO
cd /usr/local/bin
wget https://dl.min.io/server/minio/release/linux-amd64/minio
chmod +x minio
chown minio-user:minio-user minio

# Create MinIO environment file
cat > /etc/default/minio <<EOF
# MinIO local volumes
MINIO_VOLUMES="${data_dir}"

# MinIO Root credentials
MINIO_ROOT_USER=${minio_root_user}
MINIO_ROOT_PASSWORD=${minio_root_password}

# MinIO options
MINIO_OPTS="--console-address :9001"

# MinIO address
MINIO_ADDRESS=":9000"
EOF

# Create MinIO systemd service
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

# Reload systemd, enable and start MinIO
systemctl daemon-reload
systemctl enable minio
systemctl start minio

# Wait for MinIO to start
sleep 10

# Install MinIO Client (mc)
cd /usr/local/bin
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc

# Create a log file to indicate successful installation
cat > /var/log/minio-setup.log <<EOF
MinIO installation completed at $(date)
MinIO Console: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):9001
MinIO API: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):9000
Username: ${minio_root_user}
Password: ${minio_root_password}
EOF

echo "MinIO installation completed successfully"
