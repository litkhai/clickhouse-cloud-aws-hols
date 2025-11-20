# NLB SSL Termination Testing Results

## Executive Summary

**Test Date**: 2025-11-20
**Test Objective**: Validate NLB SSL termination architecture for Kafka
**Result**: ❌ **FAILED - Architecture is fundamentally incompatible with Kafka**

## Test Environment

- **AWS Region**: ap-northeast-2 (Seoul)
- **Kafka Version**: Confluent Platform 7.8.0
- **NLB DNS**: confluent-server-nlb-89e02373ca2b3bc1.elb.ap-northeast-2.amazonaws.com
- **EC2 DNS**: ec2-203-0-113-21.ap-northeast-2.compute.amazonaws.com
- **Test Client**: Python confluent-kafka library

## Infrastructure Status

### ✅ Infrastructure Deployment: SUCCESS

All AWS resources were successfully created:
- ✅ EC2 Instance (i-0123456789abcdef0)
- ✅ Network Load Balancer
- ✅ Target Group (health checks passing)
- ✅ ACM Certificate (matches NLB DNS)
- ✅ Security Groups (ports 9092, 9094 accessible)
- ✅ Kafka Broker (running with SASL_PLAINTEXT on 9092)

### ✅ Network Connectivity: SUCCESS

```bash
# NLB DNS Resolution
✓ NLB DNS resolves to 4 IP addresses

# Port Reachability Tests
✓ EC2:9092   - Port reachable (Kafka SASL_PLAINTEXT)
✓ EC2:9021   - Port reachable (Control Center)
✓ EC2:22     - Port reachable (SSH)
✓ NLB:9094   - Port reachable (NLB SSL listener)

# SSL Certificate
✓ Certificate CN: kafka-nlb
✓ Certificate SAN: confluent-server-nlb-89e02373ca2b3bc1.elb.ap-northeast-2.amazonaws.com
✓ Certificate matches NLB DNS perfectly
```

### ❌ Kafka Client Connection: FAILED

## Test Results

### Test 1: Direct EC2 Connection (SASL_PLAINTEXT)

**Configuration**:
```python
config = {
    'bootstrap.servers': 'ec2-203-0-113-21.ap-northeast-2.compute.amazonaws.com:9092',
    'security.protocol': 'SASL_PLAINTEXT',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
}
```

**Result**: ✅ **SUCCESS**
```
✓ Connected successfully!
✓ Found 59 topics
✓ Broker: {1: BrokerMetadata(1, ec2-203-0-113-21.ap-northeast-2.compute.amazonaws.com:9092)}
```

### Test 2: NLB Connection with SSL (SASL_SSL)

**Configuration**:
```python
config = {
    'bootstrap.servers': 'confluent-server-nlb-89e02373ca2b3bc1.elb.ap-northeast-2.amazonaws.com:9094',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
    'ssl.ca.location': 'certs/nlb-certificate.pem',
}
```

**Result**: ❌ **FAILED**
```
❌ Failed: KafkaError{code=_TRANSPORT,val=-195,str="Failed to get metadata: Local: Broker transport failure"}

Error Details:
SSL handshake failed: error:0A000086:SSL routines::certificate verify failed:
broker certificate could not be verified, verify that ssl.ca.location is correctly configured

Additional Error:
SSL handshake failed: connecting to a PLAINTEXT broker listener?
```

### Test 3: NLB Connection with SSL Verification Disabled

**Configuration**:
```python
config = {
    'bootstrap.servers': 'confluent-server-nlb-89e02373ca2b3bc1.elb.ap-northeast-2.amazonaws.com:9094',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
    'ssl.ca.location': 'certs/nlb-certificate.pem',
    'enable.ssl.certificate.verification': False,  # Disabled
}
```

**Result**: ⚠️ **PARTIAL SUCCESS (but not usable)**
```
✓ Initial connection succeeded
✓ Found 59 topics
✓ Broker metadata retrieved

But with errors:
❌ SSL handshake failed when connecting to advertised listener
❌ Error: "connecting to a PLAINTEXT broker listener?"
❌ Subsequent produce/consume operations fail
```

## Root Cause Analysis

### The Problem: Protocol Mismatch in Advertised Listener

```
Step 1: Client → NLB:9094 (SASL_SSL)
  ✓ Client initiates SSL handshake
  ✓ NLB terminates SSL successfully
  ✓ NLB forwards PLAINTEXT to Kafka:9092
  ✓ Kafka responds with broker metadata

Step 2: Metadata Response
  ✓ Kafka says: "I'm at ec2-203-0-113-21.ap-northeast-2.compute.amazonaws.com:9092"
  ✓ Kafka advertises listener as: SASL_PLAINTEXT (no TLS)

Step 3: Client Reconnection
  ❌ Client tries to connect to EC2:9092 with SASL_SSL (expecting SSL)
  ❌ Kafka:9092 only speaks SASL_PLAINTEXT (no SSL)
  ❌ Protocol mismatch!
  ❌ SSL handshake fails: "connecting to a PLAINTEXT broker listener?"
```

### Kafka Configuration Analysis

**Current Kafka Configuration**:
```bash
KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:29092,SASL_PLAINTEXT://0.0.0.0:9092
KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://broker:29092,SASL_PLAINTEXT://$PUBLIC_DNS:9092
KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,SASL_PLAINTEXT:SASL_PLAINTEXT
```

**The Issue**:
- Kafka advertises `SASL_PLAINTEXT` on port 9092
- Clients connecting via NLB expect `SASL_SSL`
- When clients follow the advertised listener, they attempt SSL on a non-SSL port
- Connection fails due to protocol mismatch

### Why This Architecture Cannot Work

Kafka's listener advertisement mechanism requires:
1. **Protocol Consistency**: Advertised listener protocol must match what clients use
2. **Direct Addressing**: Clients will be redirected to the advertised address
3. **End-to-End Protocol**: The same security protocol must work end-to-end

With NLB SSL termination:
- ❌ Clients connect with SASL_SSL
- ❌ Kafka advertises SASL_PLAINTEXT
- ❌ No way to reconcile this mismatch
- ❌ Kafka cannot advertise two different protocols for the same physical listener

## Attempted Workarounds

### ❌ Workaround 1: Disable SSL Certificate Verification
**Result**: Partial success but not practical
- Initial connection works
- Metadata fetch succeeds
- Subsequent connections fail
- Not usable for real clients

### ❌ Workaround 2: Multiple Advertised Listeners
**Issue**: Cannot advertise both SSL and non-SSL for same endpoint
- Kafka physical listener is PLAINTEXT (port 9092)
- Cannot advertise as both SASL_SSL and SASL_PLAINTEXT
- Would require two separate Kafka listeners

### ❌ Workaround 3: Custom Client Configuration
**Issue**: Standard Kafka clients don't support protocol switching
- Clients use single security.protocol setting
- Cannot switch between SSL and non-SSL mid-connection
- Would require custom client implementation

## Correct Architectures

### ✅ Architecture 1: End-to-End Encryption (Recommended)

```
Client (SASL_SSL) → Kafka (SASL_SSL on 9092)
```

**Configuration**:
```bash
KAFKA_LISTENERS: SASL_SSL://0.0.0.0:9092
KAFKA_ADVERTISED_LISTENERS: SASL_SSL://$PUBLIC_DNS:9092
KAFKA_SSL_KEYSTORE_LOCATION: /etc/kafka/secrets/kafka.server.keystore.jks
KAFKA_SSL_TRUSTSTORE_LOCATION: /etc/kafka/secrets/kafka.server.truststore.jks
```

**Pros**:
- ✅ Protocol consistency throughout
- ✅ True end-to-end encryption
- ✅ Works with all Kafka clients
- ✅ No protocol mismatch

**Cons**:
- Higher CPU usage on Kafka broker (SSL processing)
- Requires certificate management on Kafka broker

### ✅ Architecture 2: NLB TCP Passthrough

```
Client (SASL_SSL) → NLB:9094 (TCP passthrough) → Kafka:9092 (SASL_SSL)
```

**Configuration**:
```hcl
# NLB Listener - TCP mode (not TLS)
resource "aws_lb_listener" "kafka_ssl" {
  load_balancer_arn = aws_lb.kafka_nlb.arn
  port              = 9094
  protocol          = "TCP"  # Not "TLS"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kafka.arn
  }
}
```

**Kafka Configuration**:
```bash
KAFKA_LISTENERS: SASL_SSL://0.0.0.0:9092
KAFKA_ADVERTISED_LISTENERS: SASL_SSL://$NLB_DNS:9094
```

**Pros**:
- ✅ NLB provides HA and load balancing
- ✅ Protocol consistency
- ✅ Works with all Kafka clients

**Cons**:
- Still requires SSL on Kafka broker
- NLB doesn't terminate SSL (just forwards)

### ✅ Architecture 3: No External SSL (Testing Only)

```
Client (SASL_PLAINTEXT) → Kafka (SASL_PLAINTEXT on 9092)
```

**Configuration**:
```bash
KAFKA_LISTENERS: SASL_PLAINTEXT://0.0.0.0:9092
KAFKA_ADVERTISED_LISTENERS: SASL_PLAINTEXT://$PUBLIC_DNS:9092
```

**Use Cases**:
- ✅ Trusted networks (VPC only)
- ✅ Development/testing
- ✅ When performance is critical and network is secure

## Lessons Learned

### What Worked
1. ✅ Terraform automation for NLB + Kafka infrastructure
2. ✅ Automated certificate generation matching NLB DNS
3. ✅ ACM certificate import and lifecycle management
4. ✅ NLB TLS termination configuration
5. ✅ Target group health checks

### What Didn't Work
1. ❌ NLB SSL termination + Kafka PLAINTEXT listener
2. ❌ Protocol mismatch between client and advertised listener
3. ❌ Attempting to hide SSL termination from Kafka clients

### Key Insights
1. **Kafka's advertised listener is not optional** - Clients MUST follow it
2. **Protocol consistency is required** - Cannot mix SSL and non-SSL
3. **Load balancer SSL termination doesn't work for Kafka** - Unlike HTTP/HTTPS
4. **Kafka is protocol-aware** - It's not just TCP forwarding like HTTP

## Recommendations

### For Production Deployments
1. **Use end-to-end encryption** with Kafka handling SSL directly
2. **Use NLB in TCP passthrough mode** if load balancing is needed
3. **Do NOT use NLB TLS termination** for Kafka
4. **See terraform-confluent-aws project** for working implementation

### For This Project
1. **Keep as documentation** of what doesn't work and why
2. **Useful for infrastructure templates** (VPC, security groups, EC2 setup)
3. **Learning resource** about Kafka networking
4. **Reference for ACM + NLB automation**

## Test Scripts

Test scripts are available in the repository:
- `test_nlb_connection.py` - Tests both direct and NLB connections
- `test_nlb_no_verify.py` - Tests with SSL verification disabled
- `debug-nlb-connection.sh` - Comprehensive connectivity debugging

## Conclusion

This architecture **does not work** for Kafka due to fundamental incompatibility between:
- NLB SSL termination (protocol changes mid-stream)
- Kafka's advertised listener mechanism (requires protocol consistency)

The project successfully demonstrates infrastructure automation but fails at the application protocol level. For working Kafka SSL setups, see `terraform-confluent-aws` or implement NLB TCP passthrough mode.

**Status**: ❌ Architecture proven incompatible with Kafka
**Recommendation**: Use alternative architectures documented above
**Value**: Educational resource and infrastructure template
