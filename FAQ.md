# Frequently Asked Questions

## TLS and Certificates

### Do I need to make changes to my TLS certificates?

Yes, one change. Your broker certificates need a **Subject Alternative Name (SAN)** that includes the hostname clients use to connect to Envoy. In this demo that hostname is `envoy`; in production it would be whatever DNS name resolves to your Envoy proxy (e.g., `kafka.example.com`).

This is because the TLS handshake happens end-to-end between the client and the broker. The client connects to `envoy:9092`, but the broker responds with its certificate. If the certificate doesn't include `envoy` (or your Envoy DNS name) as a SAN, the client's hostname verification will fail.

Both primary **and** secondary cluster certificates need this SAN, since either cluster could be serving traffic after a failover.

### What is a SAN?

SAN stands for **Subject Alternative Name**. It's a field in a TLS certificate that lists additional hostnames or IP addresses the certificate is valid for, beyond the Common Name (CN). Modern TLS clients use SANs (not the CN) for hostname verification.

For example, a broker certificate might have:
```
CN = primary-broker-0
SAN = DNS:primary-broker-0, DNS:envoy, DNS:localhost
```

This certificate is valid when the client connects to any of those three hostnames. In the Envoy passthrough architecture, the `envoy` SAN is what allows clients to connect to `envoy:9092` and still trust the broker's certificate.

You can inspect a certificate's SANs with:
```bash
openssl x509 -in broker.crt -noout -text | grep -A1 "Subject Alternative Name"
```

### Does Envoy need its own TLS certificates?

No. Envoy uses `tcp_proxy` which operates at L4 (the transport layer). It forwards raw bytes without inspecting them. It has no TLS configuration, no certificates, and never sees the plaintext traffic. The entire TLS handshake happens between the client and the broker, tunneled through Envoy.

### Can I use mutual TLS (mTLS)?

Yes. Since Envoy is a transparent TCP passthrough, mTLS works the same way: the client presents its certificate to the broker, and the broker validates it. You would set `require_client_auth: true` in the broker's `kafka_api_tls` config and provide a truststore containing your client CA.

The Envoy configuration doesn't change at all - it still just forwards bytes.

### Does every broker need its own certificate, or can I use one certificate?

Either works. In this demo, each broker gets its own certificate (with CN set to the broker's hostname), but a single certificate with SANs covering all broker hostnames and the Envoy hostname works fine. A wildcard certificate (e.g., `*.example.com`) also works as long as it covers the Envoy hostname.

### Why aren't the certificate private keys locked down to 0600?

In this demo, key files are `chmod 644` because the Redpanda process runs as UID 101 inside the container, which is different from the user who generates the certificates on the host. In a production environment, you would set proper ownership (`chown 101:101`) on the key files and use more restrictive permissions.

## Architecture

### How does TLS passthrough actually work?

1. The client opens a TCP connection to `envoy:9092`
2. Envoy accepts the TCP connection and opens a new TCP connection to the upstream broker (e.g., `primary-broker-0:9092`)
3. The client sends a TLS ClientHello
4. Envoy forwards those bytes to the broker
5. The broker responds with its certificate
6. Envoy forwards the certificate back to the client
7. The TLS handshake completes between client and broker
8. All subsequent data is encrypted end-to-end; Envoy just relays encrypted bytes

Envoy never decrypts anything. From Envoy's perspective, it's just moving opaque TCP bytes.

### If advertised listeners point to Envoy, how does TLS terminate at the broker?

The `advertised_kafka_api` for the client-facing listener is set to the **Envoy** address (e.g., `envoy:9092`), not the broker address. This is correct - all client traffic must route through the proxy. When a client gets metadata, it sees every broker at `envoy:9092`, `envoy:9093`, `envoy:9094`.

TLS still terminates at the broker because Envoy's `tcp_proxy` is just a byte pipe between two TCP connections:

```
Client                    Envoy                     Broker
  |                         |                         |
  |--- TCP connect -------->|                         |
  |                         |--- TCP connect -------->|
  |                         |                         |
  |--- TLS ClientHello ---->|--- forwards bytes ----->|
  |                         |                         |
  |<--- TLS ServerCert -----|<--- forwards bytes -----|
  |                         |                         |
  |--- TLS Finished ------->|--- forwards bytes ----->|
  |                         |                         |
  |===== encrypted Kafka traffic flows both ways =====|
```

Envoy opens two independent TCP connections (client-to-Envoy and Envoy-to-broker) and copies bytes between them without interpreting them. The TLS handshake, key exchange, and decryption all happen between the client and the broker. The broker holds the private key, performs the handshake, and decrypts the traffic. Envoy never sees plaintext and has zero TLS configuration.

This is why the broker certificate must include the Envoy hostname as a SAN: the client connects to `envoy:9092` but receives a certificate from the broker. Without the Envoy hostname in the SAN, the client's hostname verification would fail because the name it connected to (`envoy`) wouldn't match the certificate.

The actual `advertised_kafka_api` config on each broker has three entries:

```yaml
advertised_kafka_api:
    - address: envoy           # Clients connect here (TLS, through Envoy)
      port: 9092
      name: internal
    - address: primary-broker-0  # Schema Registry connects here (plaintext, direct)
      port: 9091
      name: local
    - address: localhost        # Direct host access (TLS, bypasses Envoy)
      port: 19092
      name: external
```

### Why are there three Kafka listeners per broker (ports 9092, 9091, 19092)?

Each listener serves a different purpose:

| Listener | Port | TLS | Purpose |
|---|---|---|---|
| `internal` | 9092 | Yes | Client traffic through Envoy. Advertised as `envoy:<port>`. |
| `local` | 9091 | No | Schema Registry and PandaProxy internal clients. Advertised at direct broker addresses. |
| `external` | 19092+ | Yes | Direct host access, bypasses Envoy entirely. |

The `local` plaintext listener exists to avoid a **startup deadlock** (see next question).

### What is the startup deadlock, and why does the plaintext `local` listener fix it?

When TLS is enabled on the Kafka API, Redpanda's internal Schema Registry client needs to connect to the Kafka API to initialize. Without the `local` listener, the following deadlock occurs:

1. Schema Registry connects to the Kafka API, discovers the advertised address is `envoy:9092`, and tries to connect through Envoy
2. Envoy health-checks Schema Registry (HTTP on port 8081), but Schema Registry isn't initialized yet, so it returns an error
3. Envoy marks all brokers as unhealthy and stops routing traffic
4. Schema Registry can never connect through Envoy, so it never initializes
5. Permanent deadlock

The fix: give Schema Registry its own plaintext Kafka listener (`local` on port 9091) that connects directly to brokers, bypassing Envoy entirely. Schema Registry uses this listener, Envoy health-checks Schema Registry, and there's no circular dependency.

### Does the plaintext `local` listener create a security risk?

The `local` listener is only accessible within the internal Docker network (or your private network). It is not exposed to clients and is not advertised through Envoy. In production, you would ensure this listener is only reachable from the broker hosts themselves (via network policies or firewall rules). It serves the same role as any internal management port.

### Why use Schema Registry for health checks instead of the Admin API?

The Admin API (port 9644) stays available even in **recovery mode**, so Envoy can't detect that a broker is in a degraded state. Schema Registry, on the other hand, is disabled in recovery mode. This makes it an ideal health check target: if Schema Registry stops responding, Envoy correctly identifies the broker as unhealthy and fails over to the secondary cluster.

### Why does Envoy have one listener per broker (ports 9092, 9093, 9094)?

Kafka clients discover all brokers via metadata and then connect directly to specific brokers for partition leadership. If Envoy had only a single listener, the client would try to connect to the other advertised brokers and fail.

By having one Envoy listener per broker position, each with its own priority-based cluster (primary vs. secondary), the client's metadata-driven connections are transparently routed to the correct broker on either cluster.

### What does `healthy_panic_threshold: 0.0` do?

It disables Envoy's "panic mode." Normally, when the number of healthy hosts in a priority level drops below the panic threshold, Envoy routes to all hosts regardless of health status. Setting it to 0.0 means Envoy **never** does this - when all brokers in a priority level are unhealthy, traffic cleanly overflows to the next priority level (secondary cluster) instead of being sent to unhealthy primary brokers.

## Failover Behavior

### How long does failover take?

With the default configuration:
- **Primary failure detection**: ~12 seconds (3 consecutive failed health checks at 3-second intervals)
- **Failback after primary recovers**: ~6-7 seconds (2 consecutive successful health checks)

During the detection window, client connections may fail or timeout. Kafka clients with retry logic will reconnect automatically.

### Do my clients need any code changes for failover?

No application code changes are needed. Clients connect to Envoy's address and Envoy handles the routing. However, for a smoother failover experience, you should tune your client configuration:

- **`metadata_max_age_ms`**: Lower to 3000-5000ms (default is 5 minutes) so clients discover the new broker topology faster
- **`request_timeout_ms`**: Lower to 10000-20000ms for faster failure detection
- **`reconnect_backoff_ms`**: Lower to 250-500ms for faster reconnection

### What happens to consumer group offsets during failover?

Consumer group offsets are **not replicated** between clusters. After failover to the secondary cluster, consumers will start from the beginning (or wherever `auto.offset.reset` is configured) on the secondary cluster's copy of the data.

In production, you would use a replication mechanism (Redpanda Connect, MirrorMaker 2, or Remote Read Replicas) to keep data in sync, and tools like MirrorMaker's offset translation to align consumer group offsets.

### Can I verify which cluster Envoy is routing to?

Yes, several ways:

```bash
# Check Envoy health flags (healthy = primary, failed_active_hc = secondary takes over)
curl -s http://localhost:9901/clusters | grep health_flags

# Verify the TLS certificate (shows which broker is serving)
openssl s_client -connect localhost:9092 -CAfile certs/ca.crt 2>&1 | grep "subject="
# "CN = primary-broker-0" means primary, "CN = secondary-broker-0" means secondary

# Use the demo's routing display
./failover-demo.sh routing
```

## Envoy Configuration

### Does the Envoy configuration change at all for TLS passthrough?

No. The Envoy configuration is **identical** whether clients use plaintext or TLS. The `tcp_proxy` filter just forwards bytes. This is the key advantage of TLS passthrough: you get Envoy's failover capabilities without touching the Envoy config or giving Envoy access to any certificates.

### Can Envoy inspect or log the Kafka traffic when TLS passthrough is enabled?

No. With TLS passthrough, the traffic is encrypted and Envoy cannot inspect it. Envoy can only log TCP-level metadata: connection time, bytes transferred, source/destination addresses. If you need Envoy to inspect Kafka protocol details (e.g., using the Kafka broker filter for metadata rewriting), you would need to terminate TLS at Envoy instead.

### How do Envoy's health checks work if the Kafka traffic is encrypted?

Health checks and data traffic use **different ports**. Envoy sends HTTP health checks to Schema Registry on port 8081 (plaintext), while client Kafka traffic goes to port 9092 (TLS). The `health_check_config.port_value: 8081` in each endpoint tells Envoy to health-check on a different port than the data port. This separation means health checks work without any TLS configuration on Envoy.

## Production Considerations

### What changes would I need for a production deployment?

1. **DNS name for Envoy**: Replace `envoy` with a real DNS name (e.g., `kafka.example.com`) in the broker's `advertised_kafka_api` and in your certificate SANs
2. **Certificate management**: Use a proper CA (not self-signed). Integrate with your certificate rotation process
3. **Network security**: Restrict the `local` listener (port 9091) to internal traffic only via network policies
4. **Data replication**: Configure Redpanda Connect, MirrorMaker 2, or Remote Read Replicas between clusters
5. **Consumer group offset sync**: Use offset translation tools to align consumer positions across clusters
6. **Monitoring**: Export Envoy metrics to your monitoring stack; alert on health check transitions
7. **Multiple Envoy instances**: Run multiple Envoy proxies behind a load balancer for high availability of the proxy layer itself

### Can I use this with an existing load balancer (AWS NLB, HAProxy, etc.) instead of Envoy?

Yes. Any L4 (TCP) load balancer that supports health checks and priority-based routing can replace Envoy in this architecture. The TLS passthrough concept is the same regardless of the proxy: the load balancer forwards TCP bytes, and TLS terminates at the broker. AWS NLB in TCP mode and HAProxy in `mode tcp` are common alternatives. The key requirements are:

- Priority-based routing (primary preferred over secondary)
- Active health checks to detect broker failures
- TCP passthrough (no TLS termination at the proxy)

### How does this compare to terminating TLS at Envoy?

| | TLS Passthrough (this demo) | TLS Termination at Envoy |
|---|---|---|
| Envoy sees plaintext | No | Yes |
| Envoy needs certificates | No | Yes |
| Kafka protocol inspection | Not possible | Possible (Kafka broker filter) |
| Metadata rewriting | Not possible | Possible |
| Certificate management | Broker-only | Broker + Envoy |
| Client trusts | Broker certificate | Envoy certificate |
| Performance | Slightly better (no double encrypt) | Slightly worse |
| Complexity | Lower | Higher |

TLS passthrough is the right choice when your clients already have TLS configured to the broker and you don't want to change that relationship. TLS termination at Envoy is needed if you want Envoy to inspect or modify Kafka protocol traffic.
