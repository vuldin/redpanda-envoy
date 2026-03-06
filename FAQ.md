# FAQ

## TLS and certificates

### Do I need to make changes to my TLS certificates?

Yes, one change. Your broker certificates need a **Subject Alternative Name (SAN)** that includes the hostname clients use to connect to Envoy. In this demo that hostname is `envoy`; in production it would be whatever DNS name resolves to your Envoy proxy (e.g., `kafka.example.com`).

This is because the TLS handshake happens end-to-end between the client and the broker. The client connects to `envoy:9092`, but the broker responds with its certificate. If the certificate doesn't include `envoy` (or your Envoy DNS name) as a SAN, the client's hostname verification will fail.

Both primary **and** secondary cluster certificates need this SAN, since either cluster could be serving traffic after a failover.

### What is a SAN?

SAN stands for Subject Alternative Name. It's a field in a TLS certificate that lists hostnames or IP addresses the certificate is valid for, in addition to the Common Name (CN). Modern TLS clients check SANs, not the CN, for hostname verification.

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

No. Envoy uses `tcp_proxy` at L4 -- it forwards raw bytes without inspecting them. No TLS configuration, no certificates, never sees plaintext. The TLS handshake happens between the client and the broker, tunneled through Envoy.

### Can I use mutual TLS (mTLS)?

Yes. Since Envoy is a transparent TCP passthrough, mTLS works the same way: the client presents its certificate to the broker, and the broker validates it. You would set `require_client_auth: true` in the broker's `kafka_api_tls` config and provide a truststore containing your client CA.

The Envoy configuration doesn't change at all - it still just forwards bytes.

### Does every broker need its own certificate, or can I use one certificate?

Either works. In this demo, each broker gets its own certificate (with CN set to the broker's hostname), but a single certificate with SANs covering all broker hostnames and the Envoy hostname works fine. A wildcard certificate (e.g., `*.example.com`) also works as long as it covers the Envoy hostname.

### Why aren't the certificate private keys locked down to 0600?

In this demo, key files are `chmod 644` because the Redpanda process runs as UID 101 inside the container, which differs from the host user that generates the certs. In production, set proper ownership (`chown 101:101`) on the key files and use `0600` permissions.

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

The `advertised_kafka_api` for the client-facing listener is set to the **Envoy** address (e.g., `envoy:9092`), not the broker address. This is correct - all client traffic must route through the proxy. When a client gets metadata, it sees every broker at `envoy:9092`, `envoy:9093`, `envoy:9094`, `envoy:9095`, `envoy:9096`.

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

Envoy opens two TCP connections (client-to-Envoy and Envoy-to-broker) and copies bytes between them without interpreting anything. The TLS handshake, key exchange, and decryption all happen between the client and the broker. The broker holds the private key and does the decryption. Envoy never sees plaintext.

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
2. Envoy health-checks the health aggregator, which checks Schema Registry (HTTP on port 8081), but Schema Registry isn't initialized yet, so the aggregator reports unhealthy
3. Envoy marks all brokers as unhealthy and stops routing traffic
4. Schema Registry can never connect through Envoy, so it never initializes
5. Permanent deadlock

The fix: give Schema Registry its own plaintext Kafka listener (`local` on port 9091) that connects directly to brokers, bypassing Envoy entirely. Schema Registry uses this listener, Envoy health-checks Schema Registry, and there's no circular dependency.

### Does the plaintext `local` listener create a security risk?

The `local` listener is only accessible within the Docker network (or your private network). It's not exposed to clients and not advertised through Envoy. In production, restrict it to broker hosts only via network policies or firewall rules. It's the same as any other internal management port.

### What is the health aggregator, and why wasn't it needed before?

The health aggregator is a small Python HTTP server (`health-aggregator/aggregator.py`) that checks Schema Registry on every broker every 2 seconds. It exposes two HTTP endpoints: port 8080 for the primary cluster, port 8082 for secondary. Each endpoint returns 200 if a majority of that cluster's brokers are healthy (≥3/5 for primary, ≥2/3 for secondary) and 503 if quorum is lost. Envoy health-checks these two endpoints instead of individual brokers.

The earlier version of this demo (3 brokers per cluster) didn't have an aggregator. Envoy used per-broker TCP health checks -- each cluster definition independently checked its own broker and failed over that single port when it went down. If primary-broker-0 died, port 9092 would flip to secondary while ports 9093 and 9094 stayed on primary. That's split-brain routing, and Redpanda doesn't work that way. Losing a majority of brokers means the whole cluster loses Raft quorum and can't serve requests, even on the brokers that are still running.

Moving to 5 primary brokers made the split-brain problem worse and more visible. The aggregator was added so Envoy could make one quorum decision per cluster and fail over all ports together. When the aggregator returns 503 for primary, all 5 Envoy listeners flip to secondary at the same time.

### Why use Schema Registry for health checks instead of the Admin API?

The Admin API (port 9644) stays up in recovery mode, so checking it wouldn't tell Envoy anything is wrong. Schema Registry is disabled in recovery mode. So if Schema Registry stops responding, the health aggregator counts that broker as unhealthy. When enough brokers are unhealthy (quorum lost), Envoy fails over the cluster.

### Why is there a health aggregator instead of Envoy checking brokers directly?

Envoy's native health checking is per-endpoint. Without the aggregator, each Envoy listener makes independent failover decisions: if primary-broker-0 goes down, only port 9092 fails over while ports 9093-9096 stay on primary. That doesn't match how Redpanda works -- losing a majority of brokers means the whole cluster loses Raft quorum and can't serve writes, even on the remaining "healthy" brokers.

The aggregator checks all brokers and makes a single quorum decision per cluster:
- Primary: returns 200 if ≥3/5 brokers have healthy Schema Registry, 503 otherwise
- Secondary: returns 200 if ≥2/3 brokers are healthy, 503 otherwise

Envoy health-checks the aggregator instead of individual brokers. When the aggregator returns 503, all primary endpoints across all 5 Envoy clusters get marked unhealthy at once, triggering cluster-wide failover.

### How does Envoy route health checks to the aggregator instead of the broker?

Each endpoint in the Envoy config uses `health_check_config.address` to redirect health checks to the aggregator while keeping data traffic pointed at the actual broker:

```yaml
endpoint:
  address:
    socket_address:
      address: primary-broker-0     # Data traffic goes here
      port_value: 9092
  health_check_config:
    address:
      socket_address:
        address: 172.30.0.100       # Health checks go here (aggregator IP)
        port_value: 8080            # Primary cluster quorum endpoint
```

This separation means Envoy checks cluster-wide quorum (via the aggregator) but routes actual Kafka traffic to the correct individual broker.

**Important**: `health_check_config.address` requires an IP address, not a DNS hostname. Using a hostname like `health-aggregator` causes Envoy to crash with `malformed IP address`. The health aggregator is assigned a static IP (`172.30.0.100`) in Docker Compose via `networks.redpanda-net.ipv4_address`.

### Why does the Envoy config use an IP address (172.30.0.100) instead of the hostname `health-aggregator`?

Envoy's `health_check_config.address` field only accepts IP addresses, not DNS hostnames. If you use a hostname, Envoy crashes on startup with:

```
EnvoyException in c-ares callback: malformed IP address: health-aggregator
```

This is an Envoy limitation -- the `address` field in `health_check_config` is parsed as a raw IP, bypassing DNS resolution. The workaround is to give the health aggregator a static IP (`172.30.0.100`) in Docker Compose:

```yaml
health-aggregator:
  networks:
    redpanda-net:
      ipv4_address: 172.30.0.100
```

The Docker network is configured with a fixed subnet (`172.30.0.0/24`) to ensure the static IP is valid. In production, you would use a known IP or a service mesh that provides stable IPs.

### Why does Envoy have one listener per broker (ports 9092-9096)?

Kafka clients discover all brokers via metadata and then connect directly to specific brokers for partition leadership. If Envoy had only a single listener, the client would try to connect to the other advertised broker addresses and fail.

With one Envoy listener per broker position, each backed by its own priority-based cluster (primary vs. secondary), the client's metadata-driven connections get routed to the right broker on whichever cluster is active.

### Can the primary and secondary clusters have different numbers of brokers?

Yes. This demo uses an asymmetric configuration: 5 primary brokers and 3 secondary brokers. Envoy maps each primary broker to a secondary broker for failover. When the secondary cluster has fewer brokers, the extra primary ports wrap around:

| Envoy Port | Primary Broker (Priority 0) | Secondary Broker (Priority 1) |
|---|---|---|
| 9092 | primary-broker-0 | secondary-broker-0 |
| 9093 | primary-broker-1 | secondary-broker-1 |
| 9094 | primary-broker-2 | secondary-broker-2 |
| 9095 | primary-broker-3 | secondary-broker-0 (wraps) |
| 9096 | primary-broker-4 | secondary-broker-1 (wraps) |

After failover, clients on ports 9095/9096 initially connect to secondary-broker-0/1 (duplicating ports 9092/9093). The next metadata refresh (within 5 seconds, via `metadata_max_age_ms`) corrects the client's view to the 3-broker secondary topology. This brief overlap is harmless -- Kafka clients rebalance connections based on metadata.

### What does `healthy_panic_threshold: 0.0` do?

It disables Envoy's "panic mode." Normally, when the number of healthy hosts in a priority level drops below the panic threshold, Envoy routes to all hosts regardless of health status. Setting it to 0.0 means Envoy **never** does this - when all brokers in a priority level are unhealthy, traffic cleanly overflows to the next priority level (secondary cluster) instead of being sent to unhealthy primary brokers.

## Failover behavior

### How long does failover take?

With the default configuration:
- **Primary failure detection**: ~12 seconds (3 consecutive failed health checks at 3-second intervals)
- **Failback after primary recovers**: ~6-7 seconds (2 consecutive successful health checks)

During the detection window, client connections may fail or timeout. Kafka clients with retry logic reconnect automatically.

### Do my clients need any code changes for failover?

No code changes. Clients connect to Envoy's address and Envoy handles routing. You should tune your client config for faster failover though:

- **`metadata_max_age_ms`**: Lower to 3000-5000ms (default is 5 minutes) so clients discover the new broker topology faster
- **`request_timeout_ms`**: Lower to 10000-20000ms for faster failure detection
- **`reconnect_backoff_ms`**: Lower to 250-500ms for faster reconnection

### What happens to TCP connections during failover?

Envoy does **not** actively close existing TCP connections when it marks a priority level unhealthy. It only stops routing **new** connections to the failed priority. Existing connections persist until the client detects the failure.

**What happens step by step:**
1. Primary brokers go down (or enter recovery mode)
2. Envoy health checks fail after ~10-12 seconds (3 consecutive failures)
3. Envoy marks all priority 0 endpoints unhealthy; **new** connections route to secondary
4. Existing TCP connections to primary are still open — they hang until the client times out
5. Client detects timeout, refreshes metadata, establishes new connections (now routed to secondary)

**How each client recovers:**

| Client | Timeout mechanism | Recovery time |
|---|---|---|
| Python producer | `request_timeout_ms=10000` expires, then metadata refresh | ~15-20 seconds |
| Python consumer | `request_timeout_ms=20000` expires, then metadata refresh | ~20-25 seconds |
| RPK producer | 10-second per-command timeout, then retry loop | ~10-15 seconds |
| RPK consumer | 45-second per-command timeout, then retry loop | ~15-45 seconds |

**Why Envoy doesn't kill old connections:** The Envoy config has no `idle_timeout` or `max_connection_duration` on the TCP proxy. Adding these would also kill legitimately idle but healthy connections during normal operation. Instead, the clients are configured with aggressive timeouts to detect failure quickly.

The most important client setting is `metadata_max_age_ms=5000`. Without it, kafka-python caches stale broker metadata for up to 5 minutes and won't discover the failover. After a metadata refresh, the client connects through Envoy again, which now routes to the secondary cluster.

Old connections are eventually cleaned up by `connections_max_idle_ms` (20s for producer, 30s for consumer).

### What happens to consumer group offsets during failover?

Consumer group offsets are **not shared** between the two clusters. Each cluster has its own `__consumer_offsets` topic. After failover, the consumer's group doesn't exist on the secondary cluster, so there is no committed offset to resume from.

What happens next depends on the consumer's `auto_offset_reset` setting:

| `auto_offset_reset` | Behavior on secondary after failover |
|---|---|
| `earliest` | Reads all existing messages on secondary from the beginning (offset 0) |
| `latest` | Skips existing messages, only reads new messages produced after the consumer connects |
| `none` | Throws an error because no committed offset exists |

The Python consumer in this demo uses `auto_offset_reset='earliest'`, so after failover it reads everything on the secondary cluster from the start.

Neither `earliest` nor `latest` is ideal for failover:
- `earliest` may reprocess old or irrelevant data that was previously on the secondary
- `latest` may miss messages produced to secondary between the failover event and the consumer reconnecting

In production, use offset translation tools (e.g., MirrorMaker 2's `MirrorCheckpointConnector`) to map consumer offsets between clusters so consumers can resume from approximately where they left off.

### Can consumers connect directly to both clusters to avoid missing data?

Yes, but with significant trade-offs. Instead of routing consumers through Envoy, you run two consumer instances per logical consumer — one connected to each cluster:

```
Producer → Envoy → active cluster (failover handled by Envoy)

Consumer A → primary cluster (direct, always connected)
Consumer B → secondary cluster (direct, always connected)
       ↓              ↓
   Application merges, deduplicates, and reorders
```

This guarantees no data loss: whichever cluster the producer writes to, one of the consumers will read it.

**The problems:**

1. **Duplicates at the failover boundary.** Without idempotent producers, a message can land on both clusters: the producer sends to primary, the request times out (broker received it but the ack was lost), failover happens, the producer retries on secondary. Both consumers see the message.

2. **No cross-cluster ordering.** Messages 1-100 land on primary, then 101-200 on secondary. The two consumers have no way to know the global order. The application must use timestamps or sequence numbers in the message payload to merge the two streams correctly.

3. **Double the consumer resources.** Two consumer groups, two sets of partition assignments, two independent rebalancing cycles.

4. **Deduplication is on the application.** Every message needs a unique ID (producer-assigned UUID or sequence number). The application maintains a dedup cache to filter duplicates from the merged stream.

This pattern makes sense when zero message loss is non-negotiable and the application can handle deduplication. For most use cases, the simpler approach is to accept a small data gap at the failover boundary (~15-20 seconds of in-flight messages) and replicate data between clusters.

### Can I verify which cluster Envoy is routing to?

Yes, several ways:

```bash
# Check health aggregator quorum status
curl -s localhost:8080/status | python3 -m json.tool   # Primary cluster
curl -s localhost:8082/status | python3 -m json.tool   # Secondary cluster

# Check Envoy health flags (healthy = primary, failed_active_hc = secondary takes over)
curl -s http://localhost:9901/clusters | grep health_flags

# Verify the TLS certificate (shows which broker is serving)
openssl s_client -connect localhost:9092 -CAfile certs/ca.crt 2>&1 | grep "subject="
# "CN = primary-broker-0" means primary, "CN = secondary-broker-0" means secondary

# Use the demo's routing display
./failover-demo.sh routing
```

## Envoy configuration

### Does the Envoy configuration change at all for TLS passthrough?

No. The Envoy config is identical whether clients use plaintext or TLS. The `tcp_proxy` filter just forwards bytes. You get Envoy's failover without touching the Envoy config or giving Envoy access to any certificates.

### Can Envoy inspect or log the Kafka traffic when TLS passthrough is enabled?

No. With TLS passthrough, the traffic is encrypted and Envoy cannot inspect it. Envoy can only log TCP-level metadata: connection time, bytes transferred, source/destination addresses. If you need Envoy to inspect Kafka protocol details (e.g., using the Kafka broker filter for metadata rewriting), you would need to terminate TLS at Envoy instead.

### How do Envoy's health checks work if the Kafka traffic is encrypted?

Health checks and data traffic go to different places. Envoy sends HTTP health checks to the health aggregator (ports 8080/8082, plaintext), while client Kafka traffic goes to individual brokers on port 9092 (TLS). The `health_check_config.address` in each endpoint redirects health checks to the aggregator, which checks Schema Registry (port 8081) on all brokers internally. So health checks work without any TLS configuration on Envoy.

## Production considerations

### What changes would I need for a production deployment?

1. **DNS name for Envoy** -- replace `envoy` with a real DNS name (e.g., `kafka.example.com`) in `advertised_kafka_api` and in your certificate SANs
2. **Certificate management** -- use a proper CA (not self-signed) and integrate with your cert rotation process
3. **Network security** -- restrict the `local` listener (port 9091) to internal traffic only via network policies
4. **Data replication** -- configure Redpanda Connect, MirrorMaker 2, or Remote Read Replicas between clusters
5. **Consumer group offset sync** -- use offset translation tools to align consumer positions across clusters
6. **Monitoring** -- export Envoy metrics to your monitoring stack and alert on health check transitions
7. **Multiple Envoy instances** -- run multiple Envoy proxies behind a load balancer for proxy-layer HA
8. **Health aggregator HA** -- run multiple aggregator instances or embed quorum logic at the proxy layer

### Can I use this with an existing load balancer (AWS NLB, HAProxy, etc.) instead of Envoy?

Yes. Any L4 (TCP) load balancer with health checks and priority-based routing can replace Envoy here. The concept is the same: the load balancer forwards TCP bytes and TLS terminates at the broker. AWS NLB in TCP mode and HAProxy in `mode tcp` are common alternatives. You need:

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

TLS passthrough works when your clients already have TLS configured to the broker and you don't want to change that. TLS termination at Envoy is needed if you want Envoy to inspect or modify Kafka protocol traffic.
