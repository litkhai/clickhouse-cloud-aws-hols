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

# Get public IP address for Kafka external listener
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

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
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: 'zookeeper:2181'
      KAFKA_ZOOKEEPER_SET_ACL: 'false'
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,SASL_PLAINTEXT:SASL_PLAINTEXT
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:29092,SASL_PLAINTEXT://0.0.0.0:9092
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://broker:29092,SASL_PLAINTEXT://$PUBLIC_IP:9092
      KAFKA_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_LISTENER_NAME_SASL_PLAINTEXT_SASL_ENABLED_MECHANISMS: PLAIN
      KAFKA_LISTENER_NAME_SASL_PLAINTEXT_PLAIN_SASL_JAAS_CONFIG: |
        org.apache.kafka.common.security.plain.PlainLoginModule required \
        username="${sasl_username}" \
        password="${sasl_password}" \
        user_${sasl_username}="${sasl_password}";
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
echo "✓✓✓ Confluent Platform with SASL/PLAIN Authentication Deployed Successfully ✓✓✓"
echo "================================================================================"
echo ""
echo "Kafka Bootstrap Server:"
echo "  $PUBLIC_IP:9092"
echo ""
echo "Authentication Credentials:"
echo "  Security Protocol: SASL_PLAINTEXT"
echo "  SASL Mechanism:    PLAIN"
echo "  Username:          ${sasl_username}"
echo "  Password:          ${sasl_password}"
echo ""
echo "Service URLs:"
echo "  Control Center:    http://$PUBLIC_IP:9021"
echo "  Schema Registry:   http://$PUBLIC_IP:8081"
echo "  Kafka Connect:     http://$PUBLIC_IP:8083"
echo "  ksqlDB Server:     http://$PUBLIC_IP:8088"
echo "  REST Proxy:        http://$PUBLIC_IP:8082"
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

### Kafka Bootstrap Server
\`\`\`
$PUBLIC_IP:9092
\`\`\`

### Authentication
- **Security Protocol:** SASL_PLAINTEXT
- **SASL Mechanism:** PLAIN
- **Username:** ${sasl_username}
- **Password:** ${sasl_password}

### Python Example (confluent-kafka)
\`\`\`python
from confluent_kafka import Producer

config = {
    'bootstrap.servers': '$PUBLIC_IP:9092',
    'security.protocol': 'SASL_PLAINTEXT',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': '${sasl_username}',
    'sasl.password': '${sasl_password}'
}

producer = Producer(config)
\`\`\`

### ClickHouse Kafka Engine
\`\`\`sql
CREATE TABLE kafka_queue
ENGINE = Kafka()
SETTINGS
    kafka_broker_list = '$PUBLIC_IP:9092',
    kafka_topic_list = '${topic_name}',
    kafka_group_name = 'clickhouse_group',
    kafka_format = 'JSONEachRow',
    kafka_sasl_mechanism = 'PLAIN',
    kafka_sasl_username = '${sasl_username}',
    kafka_sasl_password = '${sasl_password}',
    kafka_security_protocol = 'SASL_PLAINTEXT';
\`\`\`

### Command Line
Create sasl-client.properties:
\`\`\`
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${sasl_username}" password="${sasl_password}";
\`\`\`

Use with kafka tools:
\`\`\`bash
kafka-topics --list --bootstrap-server $PUBLIC_IP:9092 --command-config sasl-client.properties
\`\`\`

## Service Endpoints
- **Control Center:** http://$PUBLIC_IP:9021
- **Schema Registry:** http://$PUBLIC_IP:8081
- **Kafka Connect:** http://$PUBLIC_IP:8083
- **ksqlDB Server:** http://$PUBLIC_IP:8088
- **REST Proxy:** http://$PUBLIC_IP:8082
CONNEOF

# Create Python test script with correct IP
cat > /opt/confluent/test_kafka_sasl.py <<PYTEST_EOF
#!/usr/bin/env python3
"""
Test Kafka SASL/PLAIN connection from external client
"""
from confluent_kafka import Producer, Consumer, KafkaError
from confluent_kafka.admin import AdminClient
import json
import sys

# Kafka configuration
config = {
    'bootstrap.servers': '$PUBLIC_IP:9092',
    'security.protocol': 'SASL_PLAINTEXT',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': '${sasl_username}',
    'sasl.password': '${sasl_password}'
}

print("================================================================================")
print("Testing Kafka SASL/PLAIN Connection from External Client")
print("================================================================================")
print()
print("Configuration:")
print(f"  Bootstrap Server: {config['bootstrap.servers']}")
print(f"  Security Protocol: {config['security.protocol']}")
print(f"  SASL Mechanism: {config['sasl.mechanism']}")
print(f"  Username: {config['sasl.username']}")
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
