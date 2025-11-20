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
    'bootstrap.servers': '203.0.113.12:9092',
    'security.protocol': 'SASL_PLAINTEXT',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret'
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
