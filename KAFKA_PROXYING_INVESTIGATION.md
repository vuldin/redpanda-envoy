# Kafka Proxying with Envoy - Investigation

## The Problem We Encountered

When we configured brokers to advertise `envoy:9092/9093/9094`, the system broke with these symptoms:
- Schema Registry returned `broker_not_available` errors
- All Envoy health checks failed
- Clients couldn't connect (`NoBrokersAvailable`)

**Root cause:** Kafka's metadata protocol creates circular dependencies when using simple TCP proxying.

## Why TCP Proxying Kafka Is Complex

### How Kafka Clients Work

1. **Bootstrap connection**: Client connects to `envoy:9092`
2. **Metadata request**: Client asks "what brokers exist?"
3. **Metadata response**: Broker replies with advertised addresses
4. **Direct connections**: Client connects directly to those advertised addresses for all subsequent traffic

### The Circular Dependency Problem

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

## Current Demo Architecture (What Works)

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

## Solutions for True Transparent Proxying

### Solution 1: Envoy Kafka Filter (Recommended)

Envoy has a **Kafka broker filter** that understands the Kafka protocol and can rewrite metadata responses.

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

**Benefits:**
- Truly transparent - clients only know about Envoy
- Works with all Kafka clients
- Brokers continue advertising their real addresses internally
- No circular dependencies

**Drawbacks:**
- More complex configuration
- Envoy needs to parse/rewrite Kafka protocol messages
- Potential performance overhead
- Requires Envoy contrib image (not included in standard builds)

**Documentation:**
- https://www.envoyproxy.io/docs/envoy/latest/configuration/listeners/network_filters/kafka_broker_filter

### Implementation Notes for Solution 1

**Critical: Use Envoy Contrib Image**

The Kafka broker filter is a **contrib extension** and is NOT included in the standard Envoy image. You must use the contrib build:

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

The standard Envoy image does not compile contrib filters to keep the binary size smaller. The contrib image includes additional filters like `kafka_broker`, `kafka_mesh`, `postgres_proxy`, `mysql_proxy`, and other extensions.

**Data Replication Required for Production**

This demo has independent primary and secondary clusters with NO data replication. During failover, you may see errors like:

```
NotLeaderForPartitionError: [Error 6]
```

**Why this happens:**
1. Producer writes to partition 0 on primary-broker-0 (via envoy:9092)
2. Primary cluster fails, Envoy routes envoy:9092 → secondary-broker-0
3. Producer (with cached metadata) tries to write to partition 0
4. Secondary-broker-0 responds: "I'm broker 0, but I don't have YOUR partition - that's on a different cluster!"

Both clusters have node IDs 0, 1, 2, but they're **different clusters** with different partition assignments.

**Solution: Implement Data Replication**

For production transparent failover, use one of these replication strategies:

1. **Redpanda Remote Read Replicas** (recommended)
   - Native Redpanda feature for failover
   - Read-only secondary cluster kept in sync
   - Automatic promotion on primary failure
   - https://docs.redpanda.com/current/deploy/deployment-option/cloud/remote-read-replicas/

2. **MirrorMaker 2.0**
   - Kafka-native replication between clusters
   - Active-passive or active-active topologies
   - Preserves consumer group offsets

3. **Redpanda Connect (formerly Benthos)**
   - Flexible streaming pipelines
   - Custom transformation during replication
   - https://docs.redpanda.com/redpanda-connect/

With replication in place:
- Both clusters have identical topics and data
- Failover is seamless - no NotLeaderForPartitionError
- Consumers can continue from their last committed offsets

**Current Demo Behavior:**

Without replication, the demo demonstrates:
- ✅ Envoy Kafka filter successfully rewrites metadata
- ✅ All client traffic flows through Envoy
- ✅ Health check-based failover routing
- ✅ Priority-based cluster selection
- ⚠️ NotLeaderForPartitionError during failover (expected without replication)
- ⚠️ Data written to primary is not available on secondary

This is sufficient for demonstrating the Kafka filter mechanics, but production requires replication.

### Solution 2: Multiple Listener Names

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

**Benefits:**
- Separates internal and external traffic
- No metadata rewriting needed
- Internal services work normally

**Drawbacks:**
- Requires client configuration (not truly transparent)
- Not all Kafka clients support listener name selection
- Still have circular routing for external traffic

### Solution 3: Network Segmentation with DNS

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

**Benefits:**
- No configuration changes needed
- Transparent to clients and brokers

**Drawbacks:**
- Complex network setup
- Fragile - easy to misconfigure
- Doesn't work well in Kubernetes/cloud environments

### Solution 4: Kafka-Aware Proxy (Alternative to Envoy)

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

## Recommendation for This Demo

**Current approach is fine for demonstrating:**
- Envoy health check detection (recovery mode, broker failures)
- Priority-based routing
- Automatic failover at the bootstrap level

**For production implementation:**
1. Use **Envoy Kafka filter** if staying with Envoy
2. Consider **Kafka Proxy** for simpler Kafka-specific needs
3. Use **Redpanda Remote Read Replicas** which has built-in failover without proxying

## Testing the Kafka Filter Approach

To test Envoy's Kafka filter, we would need to:

1. Update `envoy.yaml` to use the `kafka_broker` filter instead of `tcp_proxy`
2. Configure ID-based broker address rewrite rules
3. Keep brokers advertising their real addresses for internal traffic
4. Clients connect to envoy and see envoy addresses in metadata

**Key change:**
```yaml
# Instead of:
- name: envoy.filters.network.tcp_proxy

# Use:
- name: envoy.filters.network.kafka_broker
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.network.kafka_broker.v3.KafkaBroker
```

This would require significant Envoy configuration changes but would enable true transparent proxying.

## Conclusion

**What we learned:**
- Simple TCP proxying works for bootstrap but clients bypass it afterward
- True transparent proxying requires Kafka protocol awareness
- Circular dependencies break when brokers advertise proxy addresses
- Multiple viable solutions exist, each with tradeoffs

**For this demo:**
- Current architecture successfully demonstrates Envoy health checking and failover
- RPK clients work perfectly (connect through Envoy each time)
- Python clients work but bypass Envoy for data traffic
- This is acceptable for a PoC/demo

**For production:**
- Implement Envoy Kafka filter for true transparent proxying
- Or use purpose-built Kafka proxies
- Or use Redpanda's native failover features (Remote Read Replicas)
