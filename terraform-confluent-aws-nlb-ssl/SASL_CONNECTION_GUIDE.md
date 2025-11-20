# Confluent Platform with SASL/PLAIN Authentication - Connection Guide

## Deployment Information

**Kafka Bootstrap Server:** `203.0.113.10:9092`

**Authentication:**
- Security Protocol: `SASL_PLAINTEXT`
- SASL Mechanism: `PLAIN`
- Username: `admin`
- Password: `admin-secret`

## Service Endpoints

- **Control Center:** http://203.0.113.10:9021
- **Schema Registry:** http://203.0.113.10:8081
- **Kafka Connect:** http://203.0.113.10:8083
- **ksqlDB Server:** http://203.0.113.10:8088
- **REST Proxy:** http://203.0.113.10:8082

## Connection Examples

### Python (confluent-kafka)

```python
from confluent_kafka import Producer, Consumer
from confluent_kafka.admin import AdminClient

# Producer configuration
producer_config = {
    'bootstrap.servers': '203.0.113.10:9092',
    'security.protocol': 'SASL_PLAINTEXT',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret'
}

producer = Producer(producer_config)

# Consumer configuration
consumer_config = {
    'bootstrap.servers': '203.0.113.10:9092',
    'security.protocol': 'SASL_PLAINTEXT',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
    'group.id': 'my-consumer-group',
    'auto.offset.reset': 'earliest'
}

consumer = Consumer(consumer_config)

# Admin client configuration
admin_config = {
    'bootstrap.servers': '203.0.113.10:9092',
    'security.protocol': 'SASL_PLAINTEXT',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret'
}

admin = AdminClient(admin_config)
```

### ClickHouse Kafka Engine

```sql
CREATE TABLE kafka_queue
(
    event_id UInt64,
    timestamp DateTime,
    user_id UInt32,
    event_type String,
    value UInt32,
    metadata String
)
ENGINE = Kafka()
SETTINGS
    kafka_broker_list = '203.0.113.10:9092',
    kafka_topic_list = 'sample-data-topic',
    kafka_group_name = 'clickhouse_consumer_group',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 3,
    kafka_sasl_mechanism = 'PLAIN',
    kafka_sasl_username = 'admin',
    kafka_sasl_password = 'admin-secret',
    kafka_security_protocol = 'SASL_PLAINTEXT';
```

### Java (Kafka Client)

```java
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import java.util.Properties;

// Producer properties
Properties producerProps = new Properties();
producerProps.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, "203.0.113.10:9092");
producerProps.put("security.protocol", "SASL_PLAINTEXT");
producerProps.put("sasl.mechanism", "PLAIN");
producerProps.put("sasl.jaas.config",
    "org.apache.kafka.common.security.plain.PlainLoginModule required " +
    "username=\"admin\" " +
    "password=\"admin-secret\";");
producerProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG,
    "org.apache.kafka.common.serialization.StringSerializer");
producerProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG,
    "org.apache.kafka.common.serialization.StringSerializer");

// Consumer properties
Properties consumerProps = new Properties();
consumerProps.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, "203.0.113.10:9092");
consumerProps.put("security.protocol", "SASL_PLAINTEXT");
consumerProps.put("sasl.mechanism", "PLAIN");
consumerProps.put("sasl.jaas.config",
    "org.apache.kafka.common.security.plain.PlainLoginModule required " +
    "username=\"admin\" " +
    "password=\"admin-secret\";");
consumerProps.put(ConsumerConfig.GROUP_ID_CONFIG, "my-consumer-group");
consumerProps.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG,
    "org.apache.kafka.common.serialization.StringDeserializer");
consumerProps.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG,
    "org.apache.kafka.common.serialization.StringDeserializer");
```

### Command Line (kafka-console-producer/consumer)

Create a properties file `sasl-client.properties`:

```properties
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="admin-secret";
```

Then use it with command-line tools:

```bash
# List topics
kafka-topics --list \
  --bootstrap-server 203.0.113.10:9092 \
  --command-config sasl-client.properties

# Create topic
kafka-topics --create \
  --bootstrap-server 203.0.113.10:9092 \
  --topic my-topic \
  --partitions 3 \
  --replication-factor 1 \
  --command-config sasl-client.properties

# Produce messages
kafka-console-producer \
  --bootstrap-server 203.0.113.10:9092 \
  --topic my-topic \
  --producer.config sasl-client.properties

# Consume messages
kafka-console-consumer \
  --bootstrap-server 203.0.113.10:9092 \
  --topic my-topic \
  --from-beginning \
  --consumer.config sasl-client.properties
```

### Go (confluent-kafka-go)

```go
package main

import (
    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

func main() {
    // Producer configuration
    producer, err := kafka.NewProducer(&kafka.ConfigMap{
        "bootstrap.servers": "203.0.113.10:9092",
        "security.protocol": "SASL_PLAINTEXT",
        "sasl.mechanism":    "PLAIN",
        "sasl.username":     "admin",
        "sasl.password":     "admin-secret",
    })

    // Consumer configuration
    consumer, err := kafka.NewConsumer(&kafka.ConfigMap{
        "bootstrap.servers": "203.0.113.10:9092",
        "security.protocol": "SASL_PLAINTEXT",
        "sasl.mechanism":    "PLAIN",
        "sasl.username":     "admin",
        "sasl.password":     "admin-secret",
        "group.id":          "my-consumer-group",
        "auto.offset.reset": "earliest",
    })
}
```

### Node.js (kafkajs)

```javascript
const { Kafka } = require('kafkajs');

const kafka = new Kafka({
  clientId: 'my-app',
  brokers: ['203.0.113.10:9092'],
  sasl: {
    mechanism: 'plain',
    username: 'admin',
    password: 'admin-secret'
  }
});

const producer = kafka.producer();
const consumer = kafka.consumer({ groupId: 'my-consumer-group' });
```

## Testing SASL Connection

To verify SASL authentication is working:

```bash
# SSH to the instance
ssh -i /path/to/kenlee_seoul_key.pem ubuntu@203.0.113.10

# Create SASL config inside broker container
sudo docker exec broker bash -c 'cat > /tmp/sasl-client.properties << EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="admin-secret";
EOF'

# Test with kafka-topics command
sudo docker exec broker kafka-topics --list \
  --bootstrap-server localhost:9092 \
  --command-config /tmp/sasl-client.properties
```

## Architecture Details

### Listener Configuration

The Kafka broker is configured with two listeners:

1. **PLAINTEXT** (Internal): `broker:29092`
   - Used for inter-broker communication and internal services
   - No authentication required
   - Not accessible from outside the Docker network

2. **SASL_PLAINTEXT** (External): `0.0.0.0:9092`
   - Used for external client connections
   - Requires SASL/PLAIN authentication
   - Advertised as: `203.0.113.10:9092`

### Security Configuration

- **SASL Mechanism:** PLAIN (username/password authentication)
- **Transport:** PLAINTEXT (no TLS encryption)
- **Authentication:** Required for port 9092
- **Authorization:** Not configured (all authenticated users have full access)

### Custom Entrypoint

The broker uses a custom entrypoint script to bypass Confluent Docker image preflight checks that were failing due to JAAS/Zookeeper SASL conflicts:

```bash
#!/bin/bash
set -e

# Disable Zookeeper SASL client
export KAFKA_ZOOKEEPER_SET_ACL=false
export ZOOKEEPER_SASL_ENABLED=false

# Run the original entrypoint
exec /etc/confluent/docker/run
```

## Verified Working

✓ SASL/PLAIN authentication tested and working
✓ Topic creation with SASL credentials
✓ Message production with SASL authentication
✓ Message consumption with SASL authentication
✓ All Confluent Platform services running

## Production Recommendations

For production deployments, consider:

1. **Enable TLS:** Use `SASL_SSL` instead of `SASL_PLAINTEXT`
2. **Strong passwords:** Use complex passwords instead of simple ones
3. **ACLs:** Configure Kafka ACLs for fine-grained authorization
4. **Network security:** Restrict `allowed_cidr_blocks` in terraform.tfvars
5. **Monitoring:** Enable metrics and monitoring for all services
6. **Backup:** Configure regular backups of Kafka data
7. **High availability:** Use multiple brokers with proper replication

## Troubleshooting

### Connection refused
- Check security group allows inbound on port 9092
- Verify broker is running: `ssh ubuntu@203.0.113.10 'sudo docker ps | grep broker'`

### Authentication failed
- Verify username and password are correct
- Check SASL mechanism is set to `PLAIN`
- Ensure `security.protocol` is set to `SASL_PLAINTEXT`

### Timeout errors
- Check network connectivity to 203.0.113.10
- Verify port 9092 is accessible: `telnet 203.0.113.10 9092`
- Check broker logs: `ssh ubuntu@203.0.113.10 'sudo docker logs broker'`
