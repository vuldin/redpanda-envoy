# Kafka proxying with Envoy - investigation

## The problem we hit

When we configured brokers to advertise `envoy:9092/9093/9094`, the system broke with these symptoms:
- Schema Registry returned `broker_not_available` errors
- All Envoy health checks failed
- Clients couldn't connect (`NoBrokersAvailable`)

**Root cause:** Kafka's metadata protocol creates circular dependencies when using simple TCP proxying.

## Why TCP proxying Kafka is complex

### How Kafka clients work

1. **Bootstrap connection**: Client connects to `envoy:9092`
2. **Metadata request**: Client asks "what brokers exist?"
3. **Metadata response**: Broker replies with advertised addresses
4. **Direct connections**: Client connects directly to those advertised addresses for all subsequent traffic

### The circular dependency problem

When brokers advertise `envoy:XXXX`:

```
Client → envoy:9092 → primary-broker-0:9092
                      ↓
            Metadata: "broker-0 is at envoy:9092"
                      ↓
Client → envoy:9092 → ??? (Which broker?)
```

**But worse - internal services break:**

```
primary-broker-0 → Schema Registry
                   ↓
        "Connect to broker at envoy:9092"
                   ↓
        Schema Registry → envoy:9092 → primary-broker-0
                                        ↓
                            Circular dependency!
```

Internal Redpanda services (Schema Registry, inter-broker replication) also use the advertised Kafka addresses, creating loops.

## Current demo architecture (what works)

Our current setup demonstrates failover, but clients bypass Envoy after bootstrap:

```
1. Bootstrap:
   Python Client → envoy:9092 → primary-broker-0:9092

2. Metadata Response:
   "Brokers: primary-broker-0:9092, primary-broker-1:9092, primary-broker-2:9092"

3. Direct Connections:
   Python Client → primary-broker-0:9092 (bypasses Envoy)
   Python Client → primary-broker-1:9092 (bypasses Envoy)
   Python Client → primary-broker-2:9092 (bypasses Envoy)
```

**Why this still demonstrates failover:**
- Envoy health checks detect when primary cluster is down/in recovery mode
- Envoy routes the initial bootstrap connection to secondary cluster
- Client then connects directly to secondary brokers

**Limitation:**
- Client traffic bypasses Envoy's advanced features (rate limiting, observability, etc.)
- RPK clients work perfectly because they connect directly through Envoy each time
- Python clients work but don't benefit from Envoy after initial metadata fetch

## Solutions for true transparent proxying

### Solution 1: Envoy Kafka filter (recommended)

Envoy has a Kafka broker filter that understands the Kafka protocol and can rewrite metadata responses.

**How it works:**
1. Client connects to `envoy:9092`
2. Envoy intercepts metadata requests
3. **Envoy rewrites broker addresses** in metadata response before sending to client
4. Client thinks it's connecting to `envoy:9092/9093/9094`
5. All traffic flows through Envoy transparently

**Configuration example:**
```yaml
filter_chains:
- filters:
  - name: envoy.filters.network.kafka_broker
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.network.kafka_broker.v3.KafkaBroker
      stat_prefix: kafka
      # Rewrite advertised addresses in metadata responses
      id_based_broker_address_rewrite_spec:
        rules:
        - id: 0
          host: envoy
          port: 9092
        - id: 1
          host: envoy
          port: 9093
        - id: 2
          host: envoy
          port: 9094
```

**Pros:**
- Transparent -- clients only know about Envoy
- Works with all Kafka clients
- Brokers keep advertising their real addresses internally
- No circular dependencies

**Cons:**
- More complex config
- Envoy has to parse and rewrite Kafka protocol messages
- Some performance overhead
- Requires Envoy contrib image (not in the standard build)

**Documentation:**
- https://www.envoyproxy.io/docs/envoy/latest/configuration/listeners/network_filters/kafka_broker_filter

### Implementation notes for solution 1

**You need the Envoy contrib image.** The Kafka broker filter is a contrib extension and is not in the standard Envoy image:

```yaml
# docker-compose.yml
services:
  envoy:
    image: envoyproxy/envoy:contrib-v1.31-latest  # NOT envoyproxy/envoy:v1.31-latest
```

**Error if using standard image:**
```
could not find @type 'type.googleapis.com/envoy.extensions.filters.network.kafka_broker.v3.KafkaBroker'
```

The standard image doesn't compile contrib filters (to keep the binary small). The contrib image includes `kafka_broker`, `kafka_mesh`, `postgres_proxy`, `mysql_proxy`, and others.

**Data replication is required for production.**

This demo has independent clusters with no data replication. During failover you'll see:

```
NotLeaderForPartitionError: [Error 6]
```

**Why this happens:**
1. Producer writes to partition 0 on primary-broker-0 (via envoy:9092)
2. Primary cluster fails, Envoy routes envoy:9092 → secondary-broker-0
3. Producer (with cached metadata) tries to write to partition 0
4. Secondary-broker-0 responds: "I'm broker 0, but I don't have YOUR partition - that's on a different cluster!"

Both clusters have node IDs 0, 1, 2, but they're different clusters with different partition assignments.

**Fix: add data replication.**

For production failover, use one of:

1. **Redpanda Remote Read Replicas** -- native feature, read-only secondary kept in sync, automatic promotion on failure
   - https://docs.redpanda.com/current/deploy/deployment-option/cloud/remote-read-replicas/

2. **MirrorMaker 2.0** -- Kafka-native replication, active-passive or active-active, preserves consumer group offsets

3. **Redpanda Connect** -- flexible streaming pipelines with custom transformations
   - https://docs.redpanda.com/redpanda-connect/

With replication in place, both clusters have the same data, there's no NotLeaderForPartitionError, and consumers can pick up from their last committed offset.

**What the demo covers without replication:**

- Envoy Kafka filter rewrites metadata correctly
- All client traffic flows through Envoy
- Health check-based failover routing works
- Priority-based cluster selection works
- NotLeaderForPartitionError during failover (expected without replication)
- Data written to primary is not on secondary

Good enough for showing the mechanics. Production needs replication.

### Solution 2: Multiple listener names

Redpanda supports multiple advertised listener names. Use different addresses for internal vs external:

**Broker configuration:**
```yaml
kafka_api:
  - address: 0.0.0.0
    port: 9092
    name: internal
  - address: 0.0.0.0
    port: 9093
    name: external_proxy

advertised_kafka_api:
  - address: primary-broker-0  # For internal services
    port: 9092
    name: internal
  - address: envoy              # For external clients
    port: 9092
    name: external_proxy
```

**Client connects with:**
```python
bootstrap_servers=['envoy:9092']
# Client property to select listener:
client_listener_name='external_proxy'
```

**Pros:**
- Separates internal and external traffic
- No metadata rewriting needed
- Internal services work normally

**Cons:**
- Requires client configuration (not transparent)
- Not all Kafka clients support listener name selection
- Still has circular routing for external traffic

### Solution 3: Network segmentation with DNS

Use Docker networks and DNS to make broker hostnames resolve differently from different locations:

**Setup:**
- Clients on network A: `primary-broker-0` resolves to Envoy IP
- Brokers on network B: `primary-broker-0` resolves to actual broker IP

**Implementation:**
```yaml
# docker-compose.yml
services:
  envoy:
    networks:
      - client_network
      - broker_network

  primary-broker-0:
    networks:
      - broker_network
    hostname: primary-broker-0

  python-client:
    networks:
      - client_network
    # Custom DNS: primary-broker-0 → envoy IP
```

**Pros:**
- No configuration changes needed
- Transparent to clients and brokers

**Cons:**
- Complex network setup
- Fragile, easy to misconfigure
- Doesn't work well in Kubernetes/cloud environments

### Solution 4: Kafka-aware proxy (alternative to Envoy)

For production, consider dedicated Kafka proxies:

**Options:**
1. **Confluent REST Proxy**
   - HTTP-based Kafka access
   - True transparent failover
   - Different protocol (not native Kafka)

2. **Strimzi Kafka Bridge**
   - HTTP/gRPC to Kafka translation
   - Built for Kubernetes
   - OpenShift-friendly

3. **Conduktor Gateway**
   - Commercial Kafka proxy
   - Built-in metadata rewriting
   - Advanced features (encryption, ACLs, quotas)

4. **Kafka Proxy** (open source)
   - Purpose-built for Kafka proxying
   - Handles metadata rewriting
   - https://github.com/grepplabs/kafka-proxy

## Recommendation for this demo

The current approach is fine for showing:
- Envoy health check detection (recovery mode, broker failures)
- Priority-based routing
- Failover at the bootstrap level

For production:
1. Use the Envoy Kafka filter if staying with Envoy
2. Consider Kafka Proxy for simpler Kafka-specific needs
3. Use Redpanda Remote Read Replicas for built-in failover without proxying

## Testing the Kafka filter approach

To test Envoy's Kafka filter, you'd need to:

1. Update `envoy.yaml` to use the `kafka_broker` filter instead of `tcp_proxy`
2. Configure ID-based broker address rewrite rules
3. Keep brokers advertising their real addresses for internal traffic
4. Clients connect to envoy and see envoy addresses in metadata

The main change:
```yaml
# Instead of:
- name: envoy.filters.network.tcp_proxy

# Use:
- name: envoy.filters.network.kafka_broker
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.network.kafka_broker.v3.KafkaBroker
```

This requires reworking the Envoy config but gets you true transparent proxying.

## Takeaways

What we learned:
- Simple TCP proxying works for bootstrap but clients bypass it afterward
- Transparent proxying requires Kafka protocol awareness
- Circular dependencies break when brokers advertise proxy addresses
- Several solutions exist, each with tradeoffs

For this demo, the current architecture works: RPK clients connect through Envoy each time, Python clients work but bypass Envoy for data traffic after bootstrap. Acceptable for a PoC.

For production, either use the Envoy Kafka filter, a purpose-built Kafka proxy, or Redpanda's native Remote Read Replicas.
