# SSL Certificate Guide for NLB Termination

## Self-Signed Certificate Limitations

This deployment uses **self-signed certificates** for SSL termination at the NLB. Self-signed certificates are not trusted by default by client applications, which will cause certificate verification errors.

## Error You May See

```
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

or

```
SSL handshake failed: error:0A000086:SSL routines::certificate verify failed
```

## Solutions by Client Type

### Python (confluent-kafka)

Add `enable.ssl.certificate.verification=False` to your configuration:

```python
from confluent_kafka.admin import AdminClient

config = {
    'bootstrap.servers': 'your-nlb-dns:9094',
    'security.protocol': 'SASL_SSL',
    'sasl.mechanism': 'PLAIN',
    'sasl.username': 'admin',
    'sasl.password': 'admin-secret',
    'ssl.ca.location': 'certs/nlb-certificate.pem',
    'enable.ssl.certificate.verification': False,  # Disable verification
}

admin = AdminClient(config)
```

### Go (kafka-go or sarama)

#### Option 1: Disable TLS Verification (Testing Only)

```go
package main

import (
    "crypto/tls"
    "github.com/segmentio/kafka-go"
    "github.com/segmentio/kafka-go/sasl/plain"
)

func main() {
    mechanism := plain.Mechanism{
        Username: "admin",
        Password: "admin-secret",
    }

    dialer := &kafka.Dialer{
        Timeout:       10 * time.Second,
        DualStack:     true,
        SASLMechanism: mechanism,
        TLS: &tls.Config{
            InsecureSkipVerify: true,  // Disable certificate verification
        },
    }

    conn, err := dialer.Dial("tcp", "your-nlb-dns:9094")
    // ...
}
```

#### Option 2: Add Certificate to TLS Config

```go
import (
    "crypto/tls"
    "crypto/x509"
    "io/ioutil"
)

func main() {
    // Load CA certificate
    caCert, err := ioutil.ReadFile("certs/nlb-certificate.pem")
    if err != nil {
        panic(err)
    }

    caCertPool := x509.NewCertPool()
    caCertPool.AppendCertsFromPEM(caCert)

    tlsConfig := &tls.Config{
        RootCAs: caCertPool,
    }

    dialer := &kafka.Dialer{
        TLS: tlsConfig,
        // ... other settings
    }
}
```

### Java (Kafka Clients)

#### Option 1: Disable SSL Verification (Testing Only)

Create a custom `SSLContext` that trusts all certificates:

```java
import java.security.cert.X509Certificate;
import javax.net.ssl.*;

// Create a trust manager that does not validate certificate chains
TrustManager[] trustAllCerts = new TrustManager[] {
    new X509TrustManager() {
        public java.security.cert.X509Certificate[] getAcceptedIssuers() {
            return new X509Certificate[0];
        }
        public void checkClientTrusted(X509Certificate[] certs, String authType) {}
        public void checkServerTrusted(X509Certificate[] certs, String authType) {}
    }
};

// Install the all-trusting trust manager
SSLContext sc = SSLContext.getInstance("SSL");
sc.init(null, trustAllCerts, new java.security.SecureRandom());
HttpsURLConnection.setDefaultSSLSocketFactory(sc.getSocketFactory());
```

#### Option 2: Add Certificate to Truststore

```bash
# Create a truststore
keytool -import -alias nlb-ca -file certs/nlb-certificate.pem -keystore truststore.jks -storepass changeit

# Use in Kafka config
Properties props = new Properties();
props.put("bootstrap.servers", "your-nlb-dns:9094");
props.put("security.protocol", "SASL_SSL");
props.put("sasl.mechanism", "PLAIN");
props.put("sasl.jaas.config", "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"admin\" password=\"admin-secret\";");
props.put("ssl.truststore.location", "truststore.jks");
props.put("ssl.truststore.password", "changeit");
```

### Node.js (kafkajs)

```javascript
const { Kafka } = require('kafkajs');
const fs = require('fs');

const kafka = new Kafka({
  clientId: 'my-app',
  brokers: ['your-nlb-dns:9094'],
  ssl: {
    rejectUnauthorized: false,  // Disable certificate verification
    // Or provide CA:
    // ca: [fs.readFileSync('certs/nlb-certificate.pem', 'utf-8')],
  },
  sasl: {
    mechanism: 'plain',
    username: 'admin',
    password: 'admin-secret',
  },
});
```

### CLI Tools (kcat/kafkacat)

```bash
# Disable SSL verification
kcat -b your-nlb-dns:9094 \
  -X security.protocol=SASL_SSL \
  -X sasl.mechanism=PLAIN \
  -X sasl.username=admin \
  -X sasl.password=admin-secret \
  -X ssl.ca.location=certs/nlb-certificate.pem \
  -X enable.ssl.certificate.verification=false \
  -L
```

## Production Recommendations

For production environments, you should:

1. **Use a Real CA-Signed Certificate**: Obtain a certificate from a trusted Certificate Authority (Let's Encrypt, DigiCert, etc.)

2. **Use AWS Certificate Manager (ACM) with Public CA**:
   - Import a certificate from a public CA into ACM
   - Or use ACM to generate a certificate (if you own the domain)

3. **Never Disable Certificate Verification**: In production, always verify certificates to prevent man-in-the-middle attacks

## Alternative: Use Custom Domain with Valid Certificate

If you have a custom domain (e.g., `kafka.mycompany.com`):

1. Get a valid SSL certificate for your domain
2. Create a CNAME record pointing to your NLB DNS
3. Upload the certificate to ACM
4. Clients will trust the certificate automatically

Example:
```bash
# DNS Record
kafka.mycompany.com  CNAME  confluent-server-nlb-xxx.elb.region.amazonaws.com

# Client configuration
bootstrap.servers=kafka.mycompany.com:9094  # Uses valid certificate
```

## Testing Certificate

To verify the certificate served by NLB:

```bash
openssl s_client -connect your-nlb-dns:9094 -showcerts
```

Check that the Subject Alternative Name (SAN) matches your NLB DNS.
