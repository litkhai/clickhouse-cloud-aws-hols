#!/bin/bash
set -e

# Update system
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

# Install required packages
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    openjdk-11-jdk

# Install Docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Start and enable Docker
systemctl start docker
systemctl enable docker

# Create directory for Confluent Platform
mkdir -p /opt/confluent
cd /opt/confluent

# Get AWS EC2 metadata
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
PUBLIC_DNS=$(curl -s http://169.254.169.254/latest/meta-data/public-hostname)

echo "Instance Metadata:"
echo "  Public IP:  $PUBLIC_IP"
echo "  Public DNS: $PUBLIC_DNS"

# Generate TLS certificates with proper CA chain
echo "Generating TLS certificates with CA..."

# Step 1: Create CA (Certificate Authority)
echo "Creating Certificate Authority..."
openssl req -new -x509 \
  -keyout ca-key.pem \
  -out ca-cert.pem \
  -days 3650 \
  -passout pass:confluent \
  -subj "/C=KR/ST=Seoul/L=Seoul/O=Confluent/OU=Engineering/CN=Confluent-CA"

# Step 2: Create broker keystore and generate certificate request
echo "Creating broker keystore..."
keytool -genkeypair \
  -alias kafka-broker \
  -keyalg RSA \
  -keysize 2048 \
  -keystore kafka.server.keystore.jks \
  -storepass confluent \
  -keypass confluent \
  -dname "CN=$PUBLIC_DNS,OU=Engineering,O=Confluent,L=Seoul,ST=Seoul,C=KR" \
  -validity 3650 \
  -ext SAN=DNS:$PUBLIC_DNS,DNS:broker,DNS:localhost,IP:$PUBLIC_IP,IP:127.0.0.1

# Step 3: Create certificate signing request (CSR)
echo "Creating certificate signing request..."
keytool -certreq \
  -alias kafka-broker \
  -keystore kafka.server.keystore.jks \
  -storepass confluent \
  -keypass confluent \
  -file broker-cert-request.csr

# Step 4: Sign the certificate with CA
echo "Signing certificate with CA..."
openssl x509 -req \
  -in broker-cert-request.csr \
  -CA ca-cert.pem \
  -CAkey ca-key.pem \
  -CAcreateserial \
  -out broker-cert-signed.pem \
  -days 3650 \
  -passin pass:confluent \
  -extensions v3_req \
  -extfile <(cat <<EOF
[v3_req]
subjectAltName = DNS:$PUBLIC_DNS,DNS:broker,DNS:localhost,IP:$PUBLIC_IP,IP:127.0.0.1
EOF
)

# Step 5: Import CA certificate into broker keystore
echo "Importing CA certificate into keystore..."
keytool -importcert \
  -alias CARoot \
  -file ca-cert.pem \
  -keystore kafka.server.keystore.jks \
  -storepass confluent \
  -noprompt

# Step 6: Import signed certificate into broker keystore
echo "Importing signed certificate into keystore..."
keytool -importcert \
  -alias kafka-broker \
  -file broker-cert-signed.pem \
  -keystore kafka.server.keystore.jks \
  -storepass confluent \
  -keypass confluent \
  -noprompt

# Step 7: Create truststore and import CA certificate
echo "Creating truststore..."
keytool -importcert \
  -alias CARoot \
  -file ca-cert.pem \
  -keystore kafka.server.truststore.jks \
  -storepass confluent \
  -noprompt

# Step 8: Create client truststore (same as server truststore for self-signed CA)
cp kafka.server.truststore.jks kafka.client.truststore.jks

# Step 9: Export CA certificate for client use (PEM format)
cp ca-cert.pem kafka-ca-cert.crt

# Step 10: Create combined certificate bundle (CA + broker cert) for clients
cat broker-cert-signed.pem ca-cert.pem > kafka-broker-cert-bundle.crt

# For backward compatibility, also export just the broker certificate
openssl x509 -in broker-cert-signed.pem -out kafka-broker-cert.crt

echo "TLS certificates generated successfully!"
echo "  Primary hostname: $PUBLIC_DNS"
echo "  CA Certificate: kafka-ca-cert.crt (recommended for clients)"
echo "  Broker Certificate: kafka-broker-cert.crt"
echo "  Certificate Bundle: kafka-broker-cert-bundle.crt"

# Create Kafka JAAS configuration file (without Client section - we don't need SASL for Zookeeper)
cat > kafka_server_jaas.conf <<'JAASEOF'
KafkaServer {
   org.apache.kafka.common.security.plain.PlainLoginModule required
   username="admin"
   password="admin-secret"
   user_admin="admin-secret";
};
JAASEOF

# Create custom entrypoint script that bypasses preflight checks
cat > custom-entrypoint.sh <<'ENTRYPOINT_EOF'
#!/bin/bash
set -e

# Export zookeeper SASL client disable
export KAFKA_ZOOKEEPER_SET_ACL=false
export ZOOKEEPER_SASL_ENABLED=false

# Run the original entrypoint
exec /etc/confluent/docker/run
ENTRYPOINT_EOF

chmod +x custom-entrypoint.sh

# Create credential files for SSL
echo "confluent" > keystore_creds
echo "confluent" > key_creds
echo "confluent" > truststore_creds

# Create docker-compose.yml for Confluent Platform
cat > docker-compose.yml <<EOF
version: '3.8'

services:
  zookeeper:
    image: confluentinc/cp-zookeeper:${confluent_version}
    hostname: zookeeper
    container_name: zookeeper
    ports:
      - "2181:2181"
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    volumes:
      - zookeeper-data:/var/lib/zookeeper/data
      - zookeeper-logs:/var/lib/zookeeper/log

  broker:
    image: confluentinc/cp-kafka:${confluent_version}
    hostname: broker
    container_name: broker
    depends_on:
      - zookeeper
    ports:
      - "9092:9092"
      - "9093:9093"
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: 'zookeeper:2181'
      KAFKA_ZOOKEEPER_SET_ACL: 'false'
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,SASL_SSL:SASL_SSL,SASL_PLAINTEXT:SASL_PLAINTEXT
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:29092,SASL_SSL://0.0.0.0:9092,SASL_PLAINTEXT://0.0.0.0:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://broker:29092,SASL_SSL://$PUBLIC_DNS:9092,SASL_PLAINTEXT://$PUBLIC_DNS:9093
      KAFKA_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_LISTENER_NAME_SASL_PLAINTEXT_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_LISTENER_NAME_SASL_PLAINTEXT_PLAIN_SASL_JAAS_CONFIG: |
        org.apache.kafka.common.security.plain.PlainLoginModule required \
        username="${sasl_username}" \
        password="${sasl_password}" \
        user_${sasl_username}="${sasl_password}";
      KAFKA_LISTENER_NAME_SASL_SSL_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_LISTENER_NAME_SASL_SSL_PLAIN_SASL_JAAS_CONFIG: |
        org.apache.kafka.common.security.plain.PlainLoginModule required \
        username="${sasl_username}" \
        password="${sasl_password}" \
        user_${sasl_username}="${sasl_password}";
      KAFKA_SSL_KEYSTORE_FILENAME: kafka.server.keystore.jks
      KAFKA_SSL_KEYSTORE_CREDENTIALS: keystore_creds
      KAFKA_SSL_KEY_CREDENTIALS: key_creds
      KAFKA_SSL_TRUSTSTORE_FILENAME: kafka.server.truststore.jks
      KAFKA_SSL_TRUSTSTORE_CREDENTIALS: truststore_creds
      KAFKA_SSL_CLIENT_AUTH: 'none'
      KAFKA_OPTS: "-Djava.security.auth.login.config=/etc/kafka/kafka_server_jaas.conf -Dzookeeper.sasl.client=false"
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: 'true'
      KAFKA_LOG_RETENTION_HOURS: 168
      KAFKA_LOG_SEGMENT_BYTES: 1073741824
    volumes:
      - kafka-data:/var/lib/kafka/data
      - ./kafka_server_jaas.conf:/etc/kafka/kafka_server_jaas.conf:ro
      - ./custom-entrypoint.sh:/custom-entrypoint.sh:ro
      - ./kafka.server.keystore.jks:/etc/kafka/secrets/kafka.server.keystore.jks:ro
      - ./kafka.server.truststore.jks:/etc/kafka/secrets/kafka.server.truststore.jks:ro
      - ./keystore_creds:/etc/kafka/secrets/keystore_creds:ro
      - ./key_creds:/etc/kafka/secrets/key_creds:ro
      - ./truststore_creds:/etc/kafka/secrets/truststore_creds:ro
    entrypoint: ["/custom-entrypoint.sh"]

  schema-registry:
    image: confluentinc/cp-schema-registry:${confluent_version}
    hostname: schema-registry
    container_name: schema-registry
    depends_on:
      - broker
    ports:
      - "8081:8081"
    environment:
      SCHEMA_REGISTRY_HOST_NAME: schema-registry
      SCHEMA_REGISTRY_KAFKASTORE_BOOTSTRAP_SERVERS: 'broker:29092'
      SCHEMA_REGISTRY_LISTENERS: http://0.0.0.0:8081
      SCHEMA_REGISTRY_KAFKASTORE_SECURITY_PROTOCOL: PLAINTEXT

  connect:
    image: confluentinc/cp-kafka-connect:${confluent_version}
    hostname: connect
    container_name: connect
    depends_on:
      - broker
      - schema-registry
    ports:
      - "8083:8083"
    environment:
      CONNECT_BOOTSTRAP_SERVERS: 'broker:29092'
      CONNECT_REST_ADVERTISED_HOST_NAME: connect
      CONNECT_REST_PORT: 8083
      CONNECT_GROUP_ID: compose-connect-group
      CONNECT_CONFIG_STORAGE_TOPIC: docker-connect-configs
      CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR: 1
      CONNECT_OFFSET_FLUSH_INTERVAL_MS: 10000
      CONNECT_OFFSET_STORAGE_TOPIC: docker-connect-offsets
      CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR: 1
      CONNECT_STATUS_STORAGE_TOPIC: docker-connect-status
      CONNECT_STATUS_STORAGE_REPLICATION_FACTOR: 1
      CONNECT_KEY_CONVERTER: org.apache.kafka.connect.storage.StringConverter
      CONNECT_VALUE_CONVERTER: io.confluent.connect.avro.AvroConverter
      CONNECT_VALUE_CONVERTER_SCHEMA_REGISTRY_URL: http://schema-registry:8081
      CONNECT_PLUGIN_PATH: "/usr/share/java,/usr/share/confluent-hub-components"
      CONNECT_LOG4J_LOGGERS: org.apache.zookeeper=ERROR,org.I0Itec.zkclient=ERROR,org.reflections=ERROR

  control-center:
    image: confluentinc/cp-enterprise-control-center:${confluent_version}
    hostname: control-center
    container_name: control-center
    depends_on:
      - broker
      - schema-registry
      - connect
      - ksqldb-server
    ports:
      - "9021:9021"
    environment:
      CONTROL_CENTER_BOOTSTRAP_SERVERS: 'broker:29092'
      CONTROL_CENTER_CONNECT_CONNECT-DEFAULT_CLUSTER: 'connect:8083'
      CONTROL_CENTER_KSQL_KSQLDB1_URL: "http://ksqldb-server:8088"
      CONTROL_CENTER_KSQL_KSQLDB1_ADVERTISED_URL: "http://localhost:8088"
      CONTROL_CENTER_SCHEMA_REGISTRY_URL: "http://schema-registry:8081"
      CONTROL_CENTER_REPLICATION_FACTOR: 1
      CONTROL_CENTER_INTERNAL_TOPICS_PARTITIONS: 1
      CONTROL_CENTER_MONITORING_INTERCEPTOR_TOPIC_PARTITIONS: 1
      CONFLUENT_METRICS_TOPIC_REPLICATION: 1
      PORT: 9021

  ksqldb-server:
    image: confluentinc/cp-ksqldb-server:${confluent_version}
    hostname: ksqldb-server
    container_name: ksqldb-server
    depends_on:
      - broker
      - schema-registry
    ports:
      - "8088:8088"
    environment:
      KSQL_CONFIG_DIR: "/etc/ksql"
      KSQL_BOOTSTRAP_SERVERS: "broker:29092"
      KSQL_HOST_NAME: ksqldb-server
      KSQL_LISTENERS: "http://0.0.0.0:8088"
      KSQL_CACHE_MAX_BYTES_BUFFERING: 0
      KSQL_KSQL_SCHEMA_REGISTRY_URL: "http://schema-registry:8081"
      KSQL_PRODUCER_INTERCEPTOR_CLASSES: "io.confluent.monitoring.clients.interceptor.MonitoringProducerInterceptor"
      KSQL_CONSUMER_INTERCEPTOR_CLASSES: "io.confluent.monitoring.clients.interceptor.MonitoringConsumerInterceptor"
      KSQL_KSQL_LOGGING_PROCESSING_TOPIC_REPLICATION_FACTOR: 1
      KSQL_KSQL_LOGGING_PROCESSING_TOPIC_AUTO_CREATE: 'true'
      KSQL_KSQL_LOGGING_PROCESSING_STREAM_AUTO_CREATE: 'true'

  rest-proxy:
    image: confluentinc/cp-kafka-rest:${confluent_version}
    hostname: rest-proxy
    container_name: rest-proxy
    depends_on:
      - broker
      - schema-registry
    ports:
      - "8082:8082"
    environment:
      KAFKA_REST_HOST_NAME: rest-proxy
      KAFKA_REST_BOOTSTRAP_SERVERS: 'broker:29092'
      KAFKA_REST_LISTENERS: "http://0.0.0.0:8082"
      KAFKA_REST_SCHEMA_REGISTRY_URL: 'http://schema-registry:8081'

volumes:
  zookeeper-data:
  zookeeper-logs:
  kafka-data:
EOF

# Start Confluent Platform
docker compose up -d

# Wait for Kafka to be ready
echo "Waiting for Kafka to be ready..."
MAX_WAIT=300
ELAPSED=0
until docker exec broker kafka-broker-api-versions --bootstrap-server localhost:29092 >/dev/null 2>&1; do
  if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "ERROR: Kafka failed to start after $${MAX_WAIT} seconds"
    docker logs broker
    exit 1
  fi
  echo "Waiting for Kafka... ($ELAPSED/$MAX_WAIT seconds)"
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

echo "Kafka is ready!"

# Create sample topic
docker exec broker kafka-topics --create \
  --bootstrap-server localhost:29092 \
  --topic ${topic_name} \
  --partitions 3 \
  --replication-factor 1 \
  --if-not-exists

# Create data producer script
cat > /opt/confluent/produce-data.sh <<'PRODUCER_EOF'
#!/bin/bash

TOPIC="${topic_name}"
INTERVAL=${data_interval}

echo "Starting data producer for topic: $TOPIC"
echo "Producing data every $INTERVAL seconds"

counter=1
while true; do
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  user_id=$((RANDOM % 1000 + 1))
  event_type=("page_view" "click" "purchase" "signup" "logout")
  event=$${event_type[$RANDOM % $${#event_type[@]}]}
  value=$((RANDOM % 1000 + 1))

  message=$(cat <<EOF
{
  "event_id": $counter,
  "timestamp": "$timestamp",
  "user_id": $user_id,
  "event_type": "$event",
  "value": $value,
  "metadata": {
    "source": "web",
    "version": "1.0"
  }
}
EOF
)

  echo "$message" | docker exec -i broker kafka-console-producer \
    --broker-list localhost:29092 \
    --topic $TOPIC

  echo "[$timestamp] Produced message $counter to topic $TOPIC"
  counter=$((counter + 1))
  sleep $INTERVAL
done
PRODUCER_EOF

chmod +x /opt/confluent/produce-data.sh

# Create systemd service for data producer
cat > /etc/systemd/system/confluent-producer.service <<'SERVICE_EOF'
[Unit]
Description=Confluent Sample Data Producer
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/opt/confluent/produce-data.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Start and enable the producer service
systemctl daemon-reload
systemctl start confluent-producer
systemctl enable confluent-producer

# Create startup script
cat > /opt/confluent/start.sh <<'START_EOF'
#!/bin/bash
cd /opt/confluent
docker compose up -d
systemctl start confluent-producer
echo "Confluent Platform started successfully"
START_EOF

chmod +x /opt/confluent/start.sh

# Create stop script
cat > /opt/confluent/stop.sh <<'STOP_EOF'
#!/bin/bash
systemctl stop confluent-producer
cd /opt/confluent
docker compose down
echo "Confluent Platform stopped successfully"
STOP_EOF

chmod +x /opt/confluent/stop.sh

# Create status check script
cat > /opt/confluent/status.sh <<'STATUS_EOF'
#!/bin/bash
echo "=== Confluent Platform Status ==="
echo ""
echo "Docker Containers:"
docker compose ps
echo ""
echo "Data Producer Service:"
systemctl status confluent-producer --no-pager
echo ""
echo "Topic List:"
docker exec broker kafka-topics --list --bootstrap-server localhost:29092
STATUS_EOF

chmod +x /opt/confluent/status.sh

echo ""
echo "================================================================================"
echo "✓✓✓ Confluent Platform with SASL/PLAIN + TLS Deployed Successfully ✓✓✓"
echo "================================================================================"
echo ""
echo "Instance Information:"
echo "  Public DNS:  $PUBLIC_DNS"
echo "  Public IP:   $PUBLIC_IP"
echo ""
echo "Kafka Bootstrap Servers:"
echo "  SASL_SSL (with TLS):            $PUBLIC_DNS:9092  [PRIMARY - Recommended]"
echo "  SASL_PLAINTEXT (no encryption): $PUBLIC_DNS:9093  [FALLBACK]"
echo ""
echo "Authentication Credentials:"
echo "  SASL Mechanism:    PLAIN"
echo "  Username:          ${sasl_username}"
echo "  Password:          ${sasl_password}"
echo ""
echo "TLS Certificates:"
echo "  CA Certificate:    /opt/confluent/kafka-ca-cert.crt (recommended for clients)"
echo "  Broker Cert:       /opt/confluent/kafka-broker-cert.crt"
echo "  Cert Bundle:       /opt/confluent/kafka-broker-cert-bundle.crt (CA + broker)"
echo "  Download via:      scp -i key.pem ubuntu@$PUBLIC_DNS:/opt/confluent/kafka-ca-cert.crt ."
echo "  Note:              Use CA certificate in ssl.ca.location for proper verification"
echo ""
echo "Service URLs:"
echo "  Control Center:    http://$PUBLIC_DNS:9021"
echo "  Schema Registry:   http://$PUBLIC_DNS:8081"
echo "  Kafka Connect:     http://$PUBLIC_DNS:8083"
echo "  ksqlDB Server:     http://$PUBLIC_DNS:8088"
echo "  REST Proxy:        http://$PUBLIC_DNS:8082"
echo ""
echo "Sample Topic:        ${topic_name}"
echo ""
echo "Management Scripts:"
echo "  Status:  /opt/confluent/status.sh"
echo "  Start:   /opt/confluent/start.sh"
echo "  Stop:    /opt/confluent/stop.sh"
echo ""
echo "Testing:"
echo "  Python SASL Test: /opt/confluent/test_kafka_sasl.py"
echo "  (Requires: pip3 install confluent-kafka)"
echo ""
echo "Connection Guide:"
echo "  See /opt/confluent/CONNECTION_INFO.md for detailed examples"
echo "================================================================================"

# Create connection info file
cat > /opt/confluent/CONNECTION_INFO.md <<CONNEOF
# Confluent Platform Connection Information

## Quick Connection Details

### Kafka Bootstrap Servers
- **SASL_SSL (with TLS):** $PUBLIC_DNS:9092 [PRIMARY - Recommended]
- **SASL_PLAINTEXT (no encryption):** $PUBLIC_DNS:9093 [FALLBACK]

### Authentication
- **SASL Mechanism:** PLAIN
- **Username:** ${sasl_username}
- **Password:** ${sasl_password}

### TLS Certificates (for SASL_SSL)
- **CA Certificate:** /opt/confluent/kafka-ca-cert.crt (recommended - resolves "unknown authority" error)
- **Broker Certificate:** /opt/confluent/kafka-broker-cert.crt
- **Certificate Bundle:** /opt/confluent/kafka-broker-cert-bundle.crt (CA + broker combined)
- **Download CA Cert:** \`scp -i key.pem ubuntu@$PUBLIC_DNS:/opt/confluent/kafka-ca-cert.crt .\`
- **Important:** Use CA certificate in \`ssl.ca.location\` for proper verification without disabling checks

## Connection Examples

### Python (confluent-kafka) - SASL_SSL (with TLS) [RECOMMENDED]
\`\`\`python
from confluent_kafka import Producer

config = {
    'bootstrap.servers': '$PUBLIC_DNS:9092',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': '${sasl_username}',
    'sasl.password': '${sasl_password}',
    'ssl.ca.location': 'kafka-ca-cert.crt',  # Download CA cert from server
    # NO NEED to disable verification - CA certificate resolves the "unknown authority" error!
}

producer = Producer(config)
\`\`\`

### Python (confluent-kafka) - SASL_PLAINTEXT (no encryption)
\`\`\`python
from confluent_kafka import Producer

config = {
    'bootstrap.servers': '$PUBLIC_DNS:9093',
    'security.protocol': 'SASL_PLAINTEXT',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': '${sasl_username}',
    'sasl.password': '${sasl_password}'
}

producer = Producer(config)
\`\`\`

### ClickHouse Kafka Engine - SASL_SSL (with TLS) [RECOMMENDED]
\`\`\`sql
CREATE TABLE kafka_queue_ssl
ENGINE = Kafka()
SETTINGS
    kafka_broker_list = '$PUBLIC_DNS:9092',
    kafka_topic_list = '${topic_name}',
    kafka_group_name = 'clickhouse_group_ssl',
    kafka_format = 'JSONEachRow',
    kafka_sasl_mechanism = 'PLAIN',
    kafka_sasl_username = '${sasl_username}',
    kafka_sasl_password = '${sasl_password}',
    kafka_security_protocol = 'SASL_SSL',
    kafka_skip_broken_messages = 1;
\`\`\`

### ClickHouse Kafka Engine - SASL_PLAINTEXT (no encryption)
\`\`\`sql
CREATE TABLE kafka_queue
ENGINE = Kafka()
SETTINGS
    kafka_broker_list = '$PUBLIC_DNS:9093',
    kafka_topic_list = '${topic_name}',
    kafka_group_name = 'clickhouse_group',
    kafka_format = 'JSONEachRow',
    kafka_sasl_mechanism = 'PLAIN',
    kafka_sasl_username = '${sasl_username}',
    kafka_sasl_password = '${sasl_password}',
    kafka_security_protocol = 'SASL_PLAINTEXT';
\`\`\`

### Command Line - SASL_PLAINTEXT
Create sasl-client.properties:
\`\`\`
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${sasl_username}" password="${sasl_password}";
\`\`\`

Use with kafka tools:
\`\`\`bash
# SASL_PLAINTEXT on port 9093
kafka-topics --list --bootstrap-server $PUBLIC_DNS:9093 --command-config sasl-client.properties
\`\`\`

Note: For SASL_SSL connections on port 9092, add SSL configuration and CA certificate to the properties file.

## Service Endpoints
- **Control Center:** http://$PUBLIC_DNS:9021
- **Schema Registry:** http://$PUBLIC_DNS:8081
- **Kafka Connect:** http://$PUBLIC_DNS:8083
- **ksqlDB Server:** http://$PUBLIC_DNS:8088
- **REST Proxy:** http://$PUBLIC_DNS:8082
CONNEOF

# Create Python test script for SASL_PLAINTEXT (port 9093)
cat > /opt/confluent/test_kafka_sasl.py <<PYTEST_EOF
#!/usr/bin/env python3
"""
Test Kafka SASL/PLAINTEXT connection from external client (port 9093)
"""
from confluent_kafka import Producer, Consumer, KafkaError
from confluent_kafka.admin import AdminClient
import json
import sys

# Kafka configuration - SASL_PLAINTEXT on port 9093 (fallback, no encryption)
config = {
    'bootstrap.servers': '$PUBLIC_DNS:9093',
    'security.protocol': 'SASL_PLAINTEXT',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': '${sasl_username}',
    'sasl.password': '${sasl_password}'
}

print("================================================================================")
print("Testing Kafka SASL/PLAINTEXT Connection from External Client")
print("================================================================================")
print()
print("Configuration:")
print(f"  Bootstrap Server: {config['bootstrap.servers']}")
print(f"  Security Protocol: {config['security.protocol']}")
print(f"  SASL Mechanism: {config['sasl.mechanism']}")
print(f"  Username: {config['sasl.username']}")
print()
print("NOTE: This tests the SASL_PLAINTEXT port (9093) without TLS encryption.")
print("      For production, use SASL_SSL on port 9092 with TLS encryption and CA cert.")
print()

# Test 1: Admin Client - List Topics
print("Test 1: AdminClient - Listing topics...")
try:
    admin = AdminClient(config)
    metadata = admin.list_topics(timeout=10)
    topics = list(metadata.topics.keys())
    print(f"✓ Successfully connected! Found {len(topics)} topics:")
    for topic in sorted(topics)[:10]:  # Show first 10 topics
        print(f"  - {topic}")
    if len(topics) > 10:
        print(f"  ... and {len(topics) - 10} more topics")
    print()
except Exception as e:
    print(f"✗ Failed to connect: {e}")
    sys.exit(1)

# Test 2: Producer - Send a message
print("Test 2: Producer - Sending test message...")
try:
    producer = Producer(config)
    test_topic = 'external-sasl-test'
    test_message = {
        'test': 'external_client',
        'message': 'Hello from external machine with SASL!',
        'server': config['bootstrap.servers']
    }

    producer.produce(
        test_topic,
        key='test-key',
        value=json.dumps(test_message)
    )
    producer.flush()
    print(f"✓ Successfully produced message to topic '{test_topic}'")
    print(f"  Message: {test_message}")
    print()
except Exception as e:
    print(f"✗ Failed to produce: {e}")
    sys.exit(1)

# Test 3: Consumer - Read messages
print("Test 3: Consumer - Reading messages...")
try:
    consumer_config = {**config}
    consumer_config.update({
        'group.id': 'python-external-test-group',
        'auto.offset.reset': 'earliest',
        'enable.auto.commit': False
    })

    consumer = Consumer(consumer_config)
    consumer.subscribe([test_topic])

    print(f"  Subscribed to topic '{test_topic}'")
    print("  Polling for messages (5 second timeout)...")

    msg_count = 0
    for i in range(50):  # Try 50 times, 100ms each
        msg = consumer.poll(0.1)
        if msg is None:
            continue
        if msg.error():
            if msg.error().code() == KafkaError._PARTITION_EOF:
                continue
            print(f"  Error: {msg.error()}")
            break

        msg_count += 1
        print(f"  ✓ Received message #{msg_count}:")
        print(f"    Key: {msg.key().decode('utf-8') if msg.key() else None}")
        print(f"    Value: {msg.value().decode('utf-8')}")

        if msg_count >= 3:  # Read first 3 messages
            break

    consumer.close()

    if msg_count > 0:
        print(f"✓ Successfully consumed {msg_count} message(s)")
    else:
        print("! No messages found (topic might be empty or needs more time)")
    print()

except Exception as e:
    print(f"✗ Failed to consume: {e}")
    sys.exit(1)

print("================================================================================")
print("✓✓✓ All tests passed! External SASL/PLAIN authentication is working! ✓✓✓")
print("================================================================================")
PYTEST_EOF

chmod +x /opt/confluent/test_kafka_sasl.py
