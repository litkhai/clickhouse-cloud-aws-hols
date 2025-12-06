#!/usr/bin/env python3
"""Test Kafka connection via NLB with SSL - No certificate verification"""

from confluent_kafka import Producer
from confluent_kafka.admin import AdminClient
import sys

# NLB connection with SSL but disable certificate verification
nlb_config = {
    'bootstrap.servers': 'confluent-server-nlb-89e02373ca2b3bc1.elb.ap-northeast-2.amazonaws.com:9094',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
    'ssl.ca.location': 'certs/nlb-certificate.pem',
    'enable.ssl.certificate.verification': False,  # Disable certificate verification
}

print("=" * 80)
print("Testing NLB Connection with SSL (No Certificate Verification)")
print("=" * 80)
print()

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
