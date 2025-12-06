#!/usr/bin/env python3
"""Test Kafka connection via NLB with SSL"""

from confluent_kafka import Producer
from confluent_kafka.admin import AdminClient
import sys

# NLB connection with SSL
# Note: Using self-signed certificate requires disabling certificate verification
# For production, use a proper CA-signed certificate
nlb_config = {
    'bootstrap.servers': 'confluent-server-nlb-7a232632237e1127.elb.ap-northeast-2.amazonaws.com:9094',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
    'ssl.ca.location': 'certs/nlb-certificate.pem',
    'enable.ssl.certificate.verification': False,  # Required for self-signed certificates
}

# Direct EC2 connection without SSL
direct_config = {
    'bootstrap.servers': 'ec2-203-0-113-20.ap-northeast-2.compute.amazonaws.com:9092',
    'security.protocol': 'SASL_PLAINTEXT',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
}

print("=" * 80)
print("Testing Kafka Connections")
print("=" * 80)
print()

# Test 1: Direct EC2 connection
print("Test 1: Direct EC2 connection (SASL_PLAINTEXT)")
print("-" * 80)
try:
    admin_direct = AdminClient(direct_config)
    metadata = admin_direct.list_topics(timeout=10)
    print(f"✓ Connected successfully!")
    print(f"  Found {len(metadata.topics)} topics")
    print(f"  Broker: {metadata.brokers}")
    print()
except Exception as e:
    print(f"❌ Failed: {e}")
    print()

# Test 2: NLB connection with SSL
print("Test 2: NLB connection with SSL (SASL_SSL)")
print("-" * 80)
try:
    admin_nlb = AdminClient(nlb_config)
    metadata = admin_nlb.list_topics(timeout=10)
    print(f"✓ Connected successfully!")
    print(f"  Found {len(metadata.topics)} topics")
    print(f"  Broker: {metadata.brokers}")
    print()
except Exception as e:
    print(f"❌ Failed: {e}")
    print()
    import traceback
    traceback.print_exc()

print("=" * 80)
print("Done!")
print("=" * 80)
