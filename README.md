# Redpanda Envoy Failover PoC

Envoy proxy sits between clients and two Redpanda clusters, routing traffic to the primary and failing over to the secondary when the primary loses quorum. Clients don't need config changes or restarts.

## Architecture

### Diagram 1: Data flow and failover routing

```
  Kafka Clients (connect to envoy:9092-9096 with TLS)
          │
          │ TLS-encrypted traffic
          ▼
  ┌───────────────────────────────────────────────────────┐
  │                 Envoy Proxy (L4)                      │
  │          TCP passthrough — does NOT terminate TLS     │
  │                                                       │
  │  Port    Cluster             Priority 0   Priority 1  │
  │  ─────   ──────────────────  ──────────   ──────────  │
  │  9092    broker_0_cluster    primary-0    secondary-0 │
  │  9093    broker_1_cluster    primary-1    secondary-1 │
  │  9094    broker_2_cluster    primary-2    secondary-2 │
  │  9095    broker_3_cluster    primary-3    secondary-0 │ ← wraparound
  │  9096    broker_4_cluster    primary-4    secondary-1 │ ← wraparound
  └────────────┬─────────────────────────┬────────────────┘
               │                         │
     priority 0 (preferred)      priority 1 (failover)
               │                         │
               ▼                         ▼
  ┌────────────────────────┐  ┌───────────────────────┐
  │  Primary Cluster       │  │  Secondary Cluster    │
  │  5 brokers (TLS)       │  │  3 brokers (TLS)      │
  │                        │  │                       │
  │  primary-broker-0..4   │  │  secondary-broker-0..2│
  │  TLS terminates here   │  │  TLS terminates here  │
  └────────────────────────┘  └───────────────────────┘

  Each broker has 3 Kafka listeners:
    internal  :9092  TLS        advertised as envoy:<port>  ← Envoy/clients
    local     :9091  plaintext  advertised as <broker>:9091 ← Schema Registry, PandaProxy
    external  :19092+ TLS       advertised as localhost:<port> ← direct host access
```

### Diagram 2: Health check flow

```
  ┌──────────────────────────────────────────────────────┐
  │                   Envoy Proxy                        │
  │                                                      │
  │  All 5 clusters health-check via:                    │
  │    GET /schemas/types                                │
  │    redirected by health_check_config.address         │
  │                                                      │
  │  Priority 0 endpoints ──→ 172.30.0.100:8080          │
  │  Priority 1 endpoints ──→ 172.30.0.100:8082          │
  └──────────────────────────────┬───────────────────────┘
                                 │ HTTP health checks
                                 ▼
  ┌──────────────────────────────────────────────────────┐
  │          Health Aggregator (172.30.0.100)            │
  │                                                      │
  │  Polls Schema Registry (:8081) on all 8 brokers      │
  │  every 2 seconds                                     │
  │                                                      │
  │  :8080 → primary quorum   (≥3/5 healthy → 200,       │
  │                             else → 503)              │
  │  :8082 → secondary quorum (≥2/3 healthy → 200,       │
  │                             else → 503)              │
  └──────┬──────────────────────────────┬────────────────┘
         │ GET /schemas/types :8081     │
         ▼                              ▼
  ┌────────────────────┐  ┌──────────────────────────┐
  │  Primary Cluster   │  │  Secondary Cluster       │
  │  primary-broker-0  │  │  secondary-broker-0      │
  │  primary-broker-1  │  │  secondary-broker-1      │
  │  primary-broker-2  │  │  secondary-broker-2      │
  │  primary-broker-3  │  │                          │
  │  primary-broker-4  │  │                          │
  │  Schema Reg :8081  │  │  Schema Reg :8081        │
  └────────────────────┘  └──────────────────────────┘

  Key: Envoy never health-checks brokers directly.
  The aggregator makes the quorum decision, then Envoy
  treats the entire priority level as healthy or unhealthy
  → all 5 ports fail over together (all-or-nothing).
```

## What it does

- TLS passthrough: Envoy forwards encrypted traffic at L4; TLS terminates at the broker, not Envoy
- Clients connect to `envoy:9092-9096` with no cluster-specific config. Works with any Kafka client library.
- Asymmetric clusters: 5 primary brokers, 3 secondary brokers
- Majority-based failover: a health aggregator checks all brokers and triggers failover when the cluster loses quorum (3/5 primary or 2/3 secondary)
- All-or-nothing failover: all 5 ports switch together (not per-broker), matching Raft quorum semantics
- Recovery mode detection: Schema Registry goes down in recovery mode, so the aggregator catches it
- Priority-based routing: primary preferred when healthy, automatic failback when it recovers
- Independent clusters: each cluster has its own data (no replication in this demo)

## Prerequisites

- Docker and Docker Compose
- `yq` - YAML processor for editing broker configurations
  - Either **Go-based yq** (mikefarah/yq) or **Python-based yq** (kislyuk/yq) works
  - Go-based: `brew install yq` (macOS) or `snap install yq` (Linux) or [download from releases](https://github.com/mikefarah/yq/releases)
  - Python-based: `pip install yq`
  - Check which one you have: `yq --version`
- (Linux only) `sudo` access for setting file permissions
- (Linux only) **Increase AIO limit** — the demo runs 8 Redpanda brokers, which exceeds the default Linux async I/O limit:
  ```bash
  sudo sysctl -w fs.aio-max-nr=1048576
  ```
  Without this, some brokers will crash on startup with: `Could not setup Async I/O: ... Set /proc/sys/fs/aio-max-nr to at least ...`

  To make this permanent across reboots, add to `/etc/sysctl.conf`:
  ```
  fs.aio-max-nr = 1048576
  ```

## Quick start - recovery mode testing

This walkthrough shows Envoy refusing to route traffic to a cluster in recovery mode, and failing over to the secondary instead.

1. **Start the demo environment:**
   ```bash
   ./failover-demo.sh start
   ```

2. **Start Envoy routing monitor in a separate terminal (keep this running):**
   ```bash
   ./failover-demo.sh routing
   ```

   This shows cluster health and routing in real time. Keep it running.

3. **Start producer in one terminal:**

   **Option A: RPK-based producer (Redpanda CLI):**
   ```bash
   docker exec -it rpk-client bash /test-producer.sh
   ```

   **Option B: Python producer:**
   ```bash
   docker exec -it python-client python3 python-producer.py
   ```

4. **Start consumer in another terminal:**

   **Option A: RPK-based consumer (Redpanda CLI):**
   ```bash
   docker exec -it rpk-client bash /test-consumer.sh
   ```

   **Option B: Python consumer:**
   ```bash
   docker exec -it python-client python3 python-consumer.py
   ```

5. **Stop two brokers in primary cluster (minority failure — no failover):**
   ```bash
   docker stop primary-broker-3 primary-broker-4
   ```

   Watch the routing monitor -- the aggregator still shows 3/5 primary brokers healthy, so quorum holds and all traffic stays on primary. Clients that were connected to the 2 downed brokers get errors and reconnect to healthy ones via metadata refresh.

   **Note**: The aggregator checks every 2 seconds, but Envoy needs ~10-12 seconds to confirm (3 consecutive health check failures at 3s intervals).

6. **Stop one more primary broker (majority failure — triggers cluster-wide failover):**
   ```bash
   docker stop primary-broker-2
   ```

   Watch the routing monitor -- the aggregator now sees only 2/5 primary brokers healthy (quorum lost) and returns 503. Envoy marks all primary endpoints unhealthy at once, and all 5 ports (9092-9096) flip to secondary.

   **Note**: To trigger failover by stopping all 5: `./failover-demo.sh fail-primary`

7. **Put all primary brokers into recovery mode:**

   Since the config directories are mounted from the host, use `yq` to edit the config files directly. This works for both running and stopped brokers.

   **If you have Go-based yq (mikefarah/yq):**
   ```bash
   for i in 0 1 2 3 4; do
     yq '.redpanda.recovery_mode_enabled = true' -i redpanda-config/primary-broker-$i/redpanda.yaml
   done
   ```

   **If you have Python-based yq (kislyuk/yq):**
   ```bash
   for i in 0 1 2 3 4; do
     yq -y '.redpanda.recovery_mode_enabled = true' redpanda-config/primary-broker-$i/redpanda.yaml > /tmp/temp$i.yaml && mv /tmp/temp$i.yaml redpanda-config/primary-broker-$i/redpanda.yaml
   done
   ```

   **On Linux**, fix permissions if needed: `sudo chown -R 101:101 redpanda-config/`

   Start the stopped brokers and restart the running ones:
   ```bash
   docker start primary-broker-2 primary-broker-3 primary-broker-4
   docker restart primary-broker-0 primary-broker-1
   ```

   **Note**: `rpk redpanda mode recovery` inside the container won't work because the mounted config directory isn't writable by the Redpanda process.

8. **Verify all primary brokers are in recovery mode:**

   Wait for all brokers to come up (~10-15 seconds), then check:
   ```bash
   docker exec primary-broker-0 rpk cluster health
   ```

   Expected output:
   ```
   CLUSTER HEALTH OVERVIEW
   =======================
   Healthy:                          true
   Unhealthy reasons:                []
   Controller ID:                    0
   All nodes:                        [0 1 2 3 4]
   Nodes down:                       []
   Nodes in recovery mode:           [0 1 2 3 4]
   Leaderless partitions (0):        []
   Under-replicated partitions (0):  []
   ```

   The cluster reports "Healthy: true" but all nodes are in recovery mode. Envoy still routes to secondary because Schema Registry is disabled in recovery mode.

9. **Take primary cluster out of recovery mode:**

   **If you have Go-based yq (mikefarah/yq):**
   ```bash
   for i in 0 1 2 3 4; do
     yq 'del(.redpanda.recovery_mode_enabled)' -i redpanda-config/primary-broker-$i/redpanda.yaml
   done
   ```

   **If you have Python-based yq (kislyuk/yq):**
   ```bash
   for i in 0 1 2 3 4; do
     yq -y 'del(.redpanda.recovery_mode_enabled)' redpanda-config/primary-broker-$i/redpanda.yaml > /tmp/temp$i.yaml && mv /tmp/temp$i.yaml redpanda-config/primary-broker-$i/redpanda.yaml
   done
   ```

   **On Linux**, fix permissions if needed: `sudo chown -R 101:101 redpanda-config/`

   Restart all primary brokers:
   ```bash
   for i in 0 1 2 3 4; do docker restart primary-broker-$i; done
   ```

   As each broker exits recovery mode, Schema Registry comes back up. Once quorum is restored (≥3/5 healthy), Envoy routes traffic back to primary.

10. **Verify Envoy starts routing traffic back to primary:**

    Watch the routing monitor -- traffic shifts back to primary (priority 0) once all brokers are healthy and out of recovery mode.

    **Note**: Failback takes 6-8 seconds. Envoy requires 2 consecutive successful health checks before marking endpoints healthy.

## Files overview

- `docker-compose.yml` - Complete environment setup with volume mounts for configs
- `redpanda-config/` - Directory containing individual redpanda.yaml files for each broker
- `envoy-proxy/envoy.yaml` - Envoy configuration with health checks pointing to health aggregator
- `health-aggregator/aggregator.py` - Python HTTP server for cluster-wide majority-based health decisions
- `test-producer.sh` - RPK-based producer connecting via Envoy
- `test-consumer.sh` - RPK-based consumer connecting via Envoy
- `python-producer.py` - Python producer using kafka-python library
- `python-consumer.py` - Python consumer using kafka-python library
- `setup-topics.sh` - Creates demo topics on both clusters
- `failover-demo.sh` - Main demo orchestration script
- `generate-certs.sh` - Generates self-signed CA and per-broker TLS certificates
- `KAFKA_PROXYING_INVESTIGATION.md` - Deep dive into Kafka proxying challenges and solutions

## Configuration structure

Each broker has its own configuration file:
```
redpanda-config/
├── primary-broker-0/redpanda.yaml
├── primary-broker-1/redpanda.yaml
├── primary-broker-2/redpanda.yaml
├── primary-broker-3/redpanda.yaml
├── primary-broker-4/redpanda.yaml
├── secondary-broker-0/redpanda.yaml
├── secondary-broker-1/redpanda.yaml
└── secondary-broker-2/redpanda.yaml
```

**Important (Linux only):** On Linux, these directories must be owned by UID/GID 101:101 (Redpanda user in container):
```bash
sudo chown -R 101:101 redpanda-config/
```

Docker Desktop on macOS and Windows handles volume permissions differently and typically doesn't require this step.

## Envoy configuration

### TCP proxy (TLS passthrough)
- **Image**: `envoyproxy/envoy:v1.31-latest` (standard image — no contrib extensions needed)
- Listens on ports 9092-9096 (one per primary broker position)
- Routes to separate clusters per broker position
- TLS passthrough: Envoy forwards raw encrypted bytes without termination
- No TLS configuration on Envoy — no certs, no `transport_socket`
- Broker certificates include `envoy` as a SAN for hostname verification

### Health checking (majority-based, via health aggregator)
- **Health aggregator** checks Schema Registry (`/schemas/types`) on ALL brokers every 2 seconds
- Envoy health-checks the aggregator (every 3s) instead of individual brokers
- **Primary quorum**: aggregator port 8080 returns 200 if ≥3/5 brokers healthy, 503 if quorum lost
- **Secondary quorum**: aggregator port 8082 returns 200 if ≥2/3 brokers healthy, 503 if quorum lost
- 3 consecutive failures from aggregator mark ALL endpoints in that priority unhealthy (~10-12 seconds)
- 2 consecutive successes mark ALL endpoints healthy (~6-8 seconds)
- Detects recovery mode (Schema Registry disabled)
- 30 second ejection time for failed endpoints

### Priority-based load balancing
- **5 separate clusters**: broker_0_cluster through broker_4_cluster
- Each cluster has priority-based routing:
  - **Priority 0**: primary-broker-X (preferred)
  - **Priority 1**: secondary-broker-X (fallback, wraps around for brokers 3/4)
- Traffic only goes to secondary when primary loses quorum
- Failover is cluster-wide (all-or-nothing), matching Raft quorum semantics

| Envoy Port | Primary (Priority 0) | Secondary (Priority 1) |
|---|---|---|
| 9092 | primary-broker-0 | secondary-broker-0 |
| 9093 | primary-broker-1 | secondary-broker-1 |
| 9094 | primary-broker-2 | secondary-broker-2 |
| 9095 | primary-broker-3 | secondary-broker-0 (wraps) |
| 9096 | primary-broker-4 | secondary-broker-1 (wraps) |

### Outlier detection
- Monitors connection failures
- Ejects problematic endpoints automatically
- 50% max ejection to keep some availability

## Testing different scenarios

### 1. Normal operation
- Both clusters healthy, all traffic goes to primary
- Secondary sits idle, ready for failover

### 2. Partial primary failure (minority)
- 1-2 brokers down, quorum still holds (≥3/5 healthy)
- All traffic stays on primary
- Clients reconnect to healthy brokers via metadata refresh

### 3. Primary cluster failure (majority)
- ≥3 brokers down, quorum lost (<3/5 healthy)
- All 5 Envoy ports fail over to secondary at once
- Clients see a brief connection interruption, then reconnect
- New data goes to secondary cluster

### 4. Primary cluster recovery
- Primary becomes healthy again, traffic shifts back (all-or-nothing)
- New data goes to primary (clusters have independent data)

### 5. Both clusters unhealthy
- Envoy returns connection errors
- No healthy upstream available

## Monitoring

- **Envoy Admin**: http://localhost:9901
- **Cluster Stats**: `curl localhost:9901/stats | grep redpanda_cluster`
- **Health Check Stats**: `curl localhost:9901/stats | grep health_check`
- **Health Aggregator (primary)**: `curl -s localhost:8080/status | python3 -m json.tool`
- **Health Aggregator (secondary)**: `curl -s localhost:8082/status | python3 -m json.tool`

## Client configuration

Clients only need:
```python
bootstrap_servers=['envoy:9092']       # Bootstrap to any one Envoy port
security_protocol='SSL'                # TLS passthrough to broker
ssl_cafile='/certs/ca.crt'             # CA cert to verify broker certificate
metadata_max_age_ms=5000               # Refresh topology every 5s for fast failover
```

No cluster-specific config. Clients discover all 5 brokers via metadata.

### Client traffic flow

**RPK clients (test-consumer.sh, test-producer.sh):** All traffic goes through Envoy on every request, so failover is transparent.

**Python clients (python-producer.py, python-consumer.py):**
- Bootstrap to `envoy:9092` with TLS (`security_protocol='SSL'`)
- Discover all 5 brokers via metadata: `envoy:9092` through `envoy:9096`
- `metadata_max_age_ms=5000` refreshes topology every 5 seconds
- During failover, the next metadata refresh reveals the 3-broker secondary topology

**How it works:**
1. Client bootstraps to `envoy:9092`, Envoy forwards to primary-broker-0 (TLS passthrough)
2. Broker responds with metadata listing brokers at `envoy:9092` through `envoy:9096`
3. Client connects to each broker's Envoy port for partition operations
4. During failover, Envoy routes to secondary; next metadata refresh corrects the client's view

**Worth noting:**
- Uses the standard Envoy image (`envoyproxy/envoy:v1.31-latest`), no contrib extensions needed
- During failover you may see `NotLeaderForPartitionError` because primary and secondary are independent clusters without data replication
- For production, add data replication (Redpanda Remote Read Replicas, MirrorMaker 2, or Redpanda Connect)

See `KAFKA_PROXYING_INVESTIGATION.md` for implementation details, replication strategies, and troubleshooting.

## How recovery mode detection works

The health aggregator detects recovery mode by checking Schema Registry on each broker:

1. **Normal operation**: Schema Registry on each broker responds with HTTP 200 to `/schemas/types`
2. **Recovery mode**: Schema Registry is disabled on affected brokers → aggregator counts them as unhealthy
3. **Quorum check**: If unhealthy brokers exceed majority threshold (3/5 for primary, 2/3 for secondary), aggregator returns 503
4. **Failover**: Envoy marks ALL endpoints in that priority unhealthy and routes entire cluster to secondary

Health check configuration per endpoint:
```yaml
endpoint:
  address:
    socket_address:
      address: primary-broker-0       # Data traffic goes here
      port_value: 9092
  health_check_config:
    address:
      socket_address:
        address: 172.30.0.100         # Health checks go to aggregator (static IP)
        port_value: 8080              # Primary cluster quorum endpoint
```

**Why Schema Registry?**
- Disabled in recovery mode (unlike Admin API on port 9644)
- Simple HTTP endpoint, no authentication required
- Lightweight check: `GET /schemas/types` returns `["JSON","PROTOBUF","AVRO"]`

**Why a health aggregator?**
- Envoy's native health checking is per-endpoint — no built-in "majority" logic
- Without it, losing 1 broker would failover only that port, leaving a split-brain routing state
- The aggregator makes a single quorum decision for the entire cluster

**Why a static IP for the aggregator?** Envoy's `health_check_config.address` field requires a raw IP address. Using a DNS hostname (e.g., `health-aggregator`) causes Envoy to crash on startup with `malformed IP address: health-aggregator`. The health aggregator is assigned a static IP (`172.30.0.100`) in Docker Compose via `ipv4_address`, and the Docker network uses a fixed subnet (`172.30.0.0/24`).

## Why 5 Envoy ports?

Kafka clients discover brokers via metadata responses. Each broker advertises a unique `host:port` (e.g., `envoy:9092`, `envoy:9093`, ..., `envoy:9096`). The client then connects directly to the advertised address for partition leadership. This drives a few requirements:

**Port count matches the largest cluster.** The number of Envoy listener ports must equal the broker count of the **largest** cluster connected to Envoy. In this demo, the primary has 5 brokers, so Envoy has 5 ports (9092-9096). If Envoy only had 3 ports but the primary cluster has 5 brokers, brokers 3 and 4 would have no Envoy port to advertise — clients would get metadata pointing to addresses that don't exist, causing `ConnectionError` / `NoBrokersAvailable` for any partition led by those brokers.

**Failover to a smaller cluster.** The secondary cluster has only 3 brokers, so it uses only 3 of the 5 ports during failover. The remaining 2 ports (9095/9096) wrap around to secondary-broker-0 and secondary-broker-1. After failover, the client's next metadata refresh (within 5 seconds via `metadata_max_age_ms`) reveals only 3 brokers in the secondary cluster. The client drops connections to ports 9095/9096 and rebalances across the 3 active brokers. This brief overlap is harmless.

**Without enough ports**, clients receive metadata with broker addresses that have no corresponding Envoy listener, causing hard connection failures, `NoBrokersAvailable` exceptions, and inability to produce/consume from partitions led by the unmapped brokers. By having enough ports for the largest cluster, every broker can advertise a valid Envoy address regardless of which cluster is active.

## Production considerations

For a real deployment, you'd also need to address:

1. **Data replication** -- sync data between clusters (MirrorMaker, Redpanda Connect, etc.)
2. **Consumer group offsets** -- manage offsets across clusters
3. **DNS/service discovery** -- replace container names with real hostnames
4. **Health aggregator HA** -- run multiple aggregator instances or embed quorum logic in a sidecar
5. **Authentication** -- configure SASL/SCRAM forwarding through Envoy
6. **Monitoring** -- export Envoy and aggregator metrics to Prometheus/Grafana
7. **Data consistency** -- handle inconsistencies during failover at the application layer
8. **Health check tuning** -- adjust thresholds based on network conditions and recovery time targets
9. **Config management** -- use config management tooling to maintain broker configs at scale

## Troubleshooting

### Python client timeout constraints

The `kafka-python` library enforces ordering between timeout settings. If you change the Python client configs, these relationships must hold:

**Producer constraints:**
```
connections_max_idle_ms > request_timeout_ms > fetch_max_wait_ms
```

**Consumer constraints:**
```
connections_max_idle_ms > request_timeout_ms > session_timeout_ms > heartbeat_interval_ms
```

**Example valid configuration:**
```python
# Consumer
session_timeout_ms=12000
heartbeat_interval_ms=4000
request_timeout_ms=20000      # Must be larger than session_timeout_ms
connections_max_idle_ms=30000 # Must be larger than request_timeout_ms

# Producer
request_timeout_ms=10000
connections_max_idle_ms=20000 # Must be larger than request_timeout_ms
```

**Common errors:**
```
# Producer/Consumer
KafkaConfigurationError: connections_max_idle_ms (30000) must be larger than
request_timeout_ms (40000) which must be larger than fetch_max_wait_ms (500).

# Consumer-specific
KafkaConfigurationError: Request timeout (15000) must be larger than session timeout (20000)
```

**Why these settings matter for failover:**
- `metadata_max_age_ms=5000`: Refreshes cluster metadata every 5 seconds. The default is 5 minutes (300000ms), which is far too slow for failover. This is the single most important setting.
- `max_block_ms=15000` (producer only): How long the producer blocks waiting for metadata during send(). Keeps it from hanging on stale metadata.
- `request_timeout_ms`: Keep this low (10-15s) to fail fast and trigger metadata refresh sooner. Long timeouts delay failover discovery.
- `connections_max_idle_ms`: Must be larger than `request_timeout_ms`. Closes stale connections to failed brokers.
- `reconnect_backoff_ms` / `reconnect_backoff_max_ms`: Controls retry timing on reconnect. Lower values = faster recovery.

**Expect 15-20 seconds of downtime.** Even with aggressive metadata refresh settings, kafka-python takes time to recover during failover:
1. Time out pending requests (10-15s)
2. Refresh metadata by reconnecting to Envoy (5s)
3. Retry the failed operation

Without tuning `metadata_max_age_ms`, Python clients cache stale broker info for up to 5 minutes and won't discover the failover.

### Envoy health check tuning

The health check config in `envoy-proxy/envoy.yaml` controls how fast Envoy detects failures. Current settings detect failure in ~10-12 seconds.

**Current settings:**
```yaml
health_checks:
- timeout: 2s                       # Time to wait for health check response
  interval: 3s                      # Check every 3 seconds when healthy
  interval_jitter: 0.5s             # Random jitter to avoid thundering herd
  unhealthy_threshold: 3            # 3 consecutive failures = unhealthy
  healthy_threshold: 2              # 2 consecutive successes = healthy
  http_health_check:
    path: /schemas/types
  no_traffic_interval: 3s           # Check interval when no active connections
  unhealthy_interval: 3s            # Check interval for unhealthy endpoints
  unhealthy_edge_interval: 3s       # Interval after FIRST failure (critical!)
  healthy_edge_interval: 3s         # Interval after FIRST success
```

**Detection timeline:**

When a broker goes down:
1. First health check fails (~2s timeout)
2. Wait `unhealthy_edge_interval` (3s)
3. Second health check fails (~2s)
4. Wait `interval` (3s)
5. Third health check fails (~2s)
6. Broker marked unhealthy
**Total: ~12 seconds**

When broker recovers:
1. First health check succeeds (~200ms)
2. Wait `healthy_edge_interval` (3s)
3. Second health check succeeds (~200ms)
4. Broker marked healthy
**Total: ~6-7 seconds**

Watch out for `unhealthy_edge_interval`. It was previously set to 30 seconds, which added a long pause after the first failure before Envoy ran the second health check. Reducing it to 3s cut detection time from ~60s to ~12s.

**Common issues and solutions:**

| Issue | Symptom | Solution |
|-------|---------|----------|
| **Slow failover detection** | Takes 60+ seconds to detect failed broker | Check `unhealthy_edge_interval` - if set to 30s, reduce to 3s for faster detection |
| **Health check flapping** | Endpoints constantly switching between healthy/unhealthy | Increase `interval` and `unhealthy_threshold` to reduce sensitivity |
| **False positives during load** | Healthy brokers marked unhealthy under load | Increase `timeout` from 2s to 5s, or increase `unhealthy_threshold` from 3 to 5 |
| **Slow recovery after failover** | Primary stays inactive too long after recovery | Reduce `healthy_edge_interval` and `healthy_threshold` for faster recovery |

**Tuning by environment:**

- **Fast failover (production)**: Current settings work well (3s intervals, 2s timeout)
- **Stable network**: Drop `unhealthy_threshold` to 2 for ~8 second detection
- **Unstable network**: Raise `timeout` to 5s and `unhealthy_threshold` to 5 to avoid false positives
- **Low priority on speed**: Raise all intervals to 10s to reduce health check overhead

**Monitoring health checks:**
```bash
# View cluster health via aggregator
curl -s localhost:8080/status | python3 -m json.tool   # Primary quorum status
curl -s localhost:8082/status | python3 -m json.tool   # Secondary quorum status

# View Envoy health flags
curl -s localhost:9901/clusters | grep health_flags

# View health check stats
curl localhost:9901/stats | grep health_check
```

## Cleanup

To stop the demo:

```bash
./failover-demo.sh stop
```

**Optional: Remove all data volumes to start completely fresh:**
```bash
docker compose down -v
```

The `-v` flag removes all data, topics, and consumer offsets. On Linux, you'll need to fix permissions again afterward:

```bash
sudo chown -R 101:101 redpanda-config/
```
