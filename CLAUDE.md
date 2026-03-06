# Redpanda Envoy Failover PoC - Context for Claude

## Project Overview

This is a Proof of Concept demonstrating how Envoy proxy can facilitate transparent failover between Redpanda clusters for clients, without requiring client configuration changes or restarts. The demo includes **TLS passthrough** - TLS terminates at the Redpanda brokers (not Envoy), while Envoy forwards encrypted traffic transparently at L4.

## Architecture

```
Client Application (connects to envoy:9092 with TLS)
           ↓ (TLS encrypted)
    Envoy Proxy (L4 TCP passthrough — does NOT terminate TLS)
     ↓ (priority 0)              ↓ (priority 1)
Primary Cluster (5 brokers)  Secondary Cluster (3 brokers)
primary-broker-0..4           secondary-broker-0..2
  (TLS terminates here)        (TLS terminates here)

    Health Aggregator (checks all brokers, reports cluster quorum)
     port 8080: primary (≥3/5 healthy → 200, else → 503)
     port 8082: secondary (≥2/3 healthy → 200, else → 503)
     Envoy health-checks the aggregator, not individual brokers
```

**Asymmetric clusters**: The primary cluster has 5 brokers and the secondary has 3. During failover, Envoy ports 9095/9096 (which normally map to primary-broker-3/4) wrap around to secondary-broker-0/1. Clients discover the correct 3-broker topology via metadata refresh within 5 seconds.

## Key Components

### Services in Docker Compose
- **primary-broker-0/1/2/3/4**: Primary Redpanda cluster (5 brokers)
- **secondary-broker-0/1/2**: Secondary Redpanda cluster (3 brokers)
- **health-aggregator**: Checks all brokers' Schema Registry, exposes cluster-wide quorum status on ports 8080 (primary) and 8082 (secondary)
- **envoy-proxy**: TCP proxy listening on ports 9092-9096, routes to clusters with priority-based failover. Health-checks the aggregator instead of individual brokers.
- **rpk-client**: Container with RPK-based test scripts
- **python-client**: Python 3.11 container with kafka-python library for Python-based testing

### Configuration Files
- **docker-compose.yml**: Complete environment setup with volume mounts (including TLS cert mounts)
- **redpanda-config/[broker-name]/redpanda.yaml**: Individual broker configurations with `kafka_api_tls` enabled
- **envoy-proxy/envoy.yaml**: Envoy TCP proxy with health checks pointing to health-aggregator (no TLS config needed - passthrough)
- **health-aggregator/aggregator.py**: Python HTTP server that aggregates per-broker Schema Registry checks into cluster-wide quorum decisions
- **generate-certs.sh**: Generates self-signed CA and per-broker TLS certificates
- **certs/**: Generated TLS certificates (CA + per-broker certs with `envoy` SAN)
- **test-producer.sh**: RPK-based producer connecting via Envoy with TLS
- **test-consumer.sh**: RPK-based consumer with retry logic, signal handling, and TLS
- **python-producer.py**: Python producer using kafka-python library with SSL
- **python-consumer.py**: Python consumer using kafka-python library with SSL
- **setup-topics.sh**: Creates topics on both clusters (with TLS flags)
- **failover-demo.sh**: Main orchestration script (generates certs on start)

## Important Configuration Details

### Cluster-wide Majority-based Failover
- **Health aggregator** container checks all brokers' Schema Registry (port 8081) every 2 seconds
- Envoy health-checks the aggregator (not individual brokers) via `health_check_config.address`
- **Primary cluster**: aggregator port 8080 returns 200 if ≥3/5 brokers healthy, 503 otherwise
- **Secondary cluster**: aggregator port 8082 returns 200 if ≥2/3 brokers healthy, 503 otherwise
- When aggregator returns 503, ALL endpoints in that priority level are marked unhealthy simultaneously → cluster-wide failover
- This prevents partial failover where some ports route to primary and others to secondary

### Envoy Priority-based Load Balancing
- Priority 0: primary-broker-0/1/2/3/4 (Primary cluster) - preferred when healthy
- Priority 1: secondary-broker-0/1/2 (Secondary cluster) - used when primary unhealthy
- Envoy ports 9095/9096 wrap to secondary-broker-0/1 during failover (asymmetric mapping)
- Health checks every 3 seconds via HTTP to health-aggregator
- 30-second ejection time for failed endpoints

### Schema Registry Health Check Strategy
- **Traffic endpoint**: Kafka API on port 9092
- **Health check target**: Health aggregator (which checks Schema Registry on all brokers)
- **Path**: `GET /schemas/types` (same path on aggregator and Schema Registry)
- **Recovery mode detection**: Schema Registry is disabled in recovery mode → aggregator detects it
- **Advantage**: Admin API (port 9644) stays available in recovery mode, but Schema Registry doesn't

### TLS Passthrough
- **Envoy does NOT terminate TLS** — the `tcp_proxy` filter forwards raw encrypted bytes
- **TLS terminates at the broker** — Redpanda handles the TLS handshake directly with the client
- **No TLS config on Envoy listeners** — no `transport_socket`, no certs on Envoy side
- **Broker certs include `envoy` as a SAN** — clients connect to hostname `envoy`, so the broker cert must be valid for that hostname for TLS verification to succeed
- **Schema Registry stays plaintext** — health checks from Envoy to Schema Registry (port 8081) remain HTTP, not HTTPS. This is internal traffic on the Docker network.
- **Certificate generation**: `./generate-certs.sh` creates a self-signed CA and per-broker certs. Each broker cert has SANs: `<broker-hostname>`, `envoy`, `localhost`
- **Cert mount**: `./certs` directory mounted read-only into all broker and client containers

### Three Kafka Listeners per Broker
Each broker has 3 Kafka API listeners to separate client, internal, and external traffic:
- **`internal` (port 9092, TLS)**: Used by Envoy proxy / external clients. Advertised as `envoy:<port>` (9092-9096) so clients always route through Envoy.
- **`local` (port 9091, plaintext)**: Used by Schema Registry and PandaProxy internal clients. Advertised at direct broker addresses (e.g., `primary-broker-0:9091`). This avoids a startup deadlock where Schema Registry needs Envoy, but Envoy health-checks Schema Registry.
- **`external` (port 19092-19096, TLS)**: Direct host access, bypasses Envoy. Advertised at `localhost:<port>`.

The `schema_registry_client` and `pandaproxy_client` sections point to the `local` listener (port 9091) on all 5 primary brokers so internal components connect directly to brokers without going through Envoy.

### Redpanda Configuration
- Each broker uses a dedicated redpanda.yaml config file
- Configuration mounted as volume: `./redpanda-config/[broker-name]:/etc/redpanda`
- **TLS enabled on Kafka API**: Each broker has `kafka_api_tls` on `internal` (port 9092) and `external` listeners
  - `local` listener (port 9091) is plaintext for Schema Registry/PandaProxy internal clients
  - Certs at `/etc/redpanda/certs/` (mounted from `./certs/`)
  - `require_client_auth: false` (server-side TLS only, no mTLS)
- **Important (Linux only)**: Config directories must be owned by UID/GID 101:101 (redpanda user)
  - Docker Desktop on macOS/Windows handles permissions automatically
- Enable recovery mode by setting `recovery_mode_enabled: true` in the `redpanda:` section
  - Go-based yq: `yq '.redpanda.recovery_mode_enabled = true' -i redpanda-config/[broker]/redpanda.yaml`
  - Python-based yq: `yq -y '.redpanda.recovery_mode_enabled = true' file.yaml > temp.yaml && mv temp.yaml file.yaml`

### Test Client Containers

**RPK Test Client:**
- Uses Redpanda image with overridden entrypoint (`/bin/bash`)
- RPK-based scripts with `--tls-enabled --tls-truststore /certs/ca.crt` flags
- Consumer script has proper signal handling for Ctrl+C
- Producer sends messages every 2 seconds with timestamps

**Python Test Client:**
- Python 3.11-slim image
- Uses kafka-python library with `security_protocol='SSL'` and `ssl_cafile='/certs/ca.crt'`
- Producer: Sends messages every 2 seconds with delivery callbacks
- Consumer: Auto-commit enabled, starts from earliest offset if no previous offset
- Demonstrates real-world TLS client behavior and failover handling

## Common Commands

```bash
# Start complete environment
./failover-demo.sh start

# Check health and routing
./failover-demo.sh status
./failover-demo.sh routing
./failover-demo.sh replication

# Test failover
./failover-demo.sh fail-primary
./failover-demo.sh restore-primary

# Run test clients (RPK-based)
docker exec -it rpk-client bash /test-producer.sh
docker exec -it rpk-client bash /test-consumer.sh

# Run Python clients
docker exec -it python-client python3 python-producer.py
docker exec -it python-client python3 python-consumer.py

# Monitor services
docker logs envoy-proxy -f
docker logs redpanda-migrator -f

# Stop everything
./failover-demo.sh stop
```

## Known Issues & Solutions

### Envoy Configuration
- Priority must be set at endpoint group level, not individual LbEndpoint level
- TCP proxy access logs are simpler than HTTP (no custom formatting)
- Health checks use `health_check_config.address` to redirect to health-aggregator (static IP `172.30.0.100`)
- `health_check_config.address` requires an IP address (DNS hostnames cause Envoy to crash)
- Health aggregator uses a static IP (`172.30.0.100`) via Docker Compose `ipv4_address`

### Redpanda Configuration
- **Permission issue (Linux only)**: Mounted config directories need UID/GID 101:101 ownership
  ```bash
  sudo chown -R 101:101 redpanda-config/
  ```
  Note: Docker Desktop on macOS and Windows handle volume permissions automatically and don't require this step
- **Recovery mode**: Set via `rpk redpanda mode recovery` (running broker) or use `yq` for stopped brokers:
  ```bash
  # Go-based yq (mikefarah/yq):
  yq '.redpanda.recovery_mode_enabled = true' -i redpanda-config/[broker]/redpanda.yaml

  # Python-based yq (kislyuk/yq):
  yq -y '.redpanda.recovery_mode_enabled = true' file.yaml > temp.yaml && mv temp.yaml file.yaml
  ```
- **Node IDs**: Use 0-based indexing (0, 1, 2, 3, 4) not 1-based

### Test Client Issues
- Container uses `rpk` as entrypoint by default - must override with `/bin/bash`
- Consumer script needs proper signal handling to allow Ctrl+C exit
- No Python dependencies needed with RPK-based approach

### Health Check Debugging
- Check Envoy cluster status: `curl localhost:9901/clusters | grep health_flags`
- Check aggregator primary status: `curl -s localhost:8080/status | python3 -m json.tool`
- Check aggregator secondary status: `curl -s localhost:8082/status | python3 -m json.tool`
- Check Schema Registry directly: `curl http://localhost:18081/schemas/types`
- Check Admin API: `curl http://localhost:9644/v1/brokers | jq '.[] | {node_id, recovery_mode_enabled}'`

## Networking
- All services on `redpanda-net` bridge network (subnet `172.30.0.0/24`)
- Health aggregator has static IP `172.30.0.100` (required by Envoy's `health_check_config.address`)
- Client connections go through envoy:9092
- Internal cluster communication on standard ports
- External access: 19092-19096 (Primary brokers 0-4), 29092-29094 (Secondary), 9901 (Envoy admin), 8080/8082 (Health aggregator)

## Data Consistency
- Primary and Secondary clusters are **independent** (no replication in this demo)
- Each cluster maintains its own data
- Failover demonstrates routing capabilities, not data synchronization
- In production, use Redpanda Remote Read Replicas, MirrorMaker2, or Redpanda Connect for replication
- Consumer group state is NOT replicated - consumers restart from beginning after failover

## Monitoring & Observability
- Envoy admin interface: http://localhost:9901
- Envoy stats show cluster health, connection counts, priority levels
- Custom health check scripts show container status and connectivity
- Schema Registry health on port 18081 (primary-broker-0), 18084 (primary-broker-1), 18086 (primary-broker-2), 18088 (primary-broker-3), 18090 (primary-broker-4)

## Recovery Mode Testing

### What Gets Disabled in Recovery Mode
From [Redpanda Recovery Mode Docs](https://docs.redpanda.com/current/manage/recovery-mode/):
- **Kafka API** (fetch and produce requests) ❌
- **HTTP Proxy** ❌
- **Schema Registry** ❌ ← This is what Envoy checks!
- **Partition and leader balancers** ❌
- **Tiered Storage housekeeping** ❌
- **Compaction** ❌

### What Stays Available
- **Admin API** (port 9644) ✅
- **RPC API** (port 33145) ✅

### Enabling Recovery Mode
**For running broker:**
```bash
docker exec -it primary-broker-0 rpk redpanda mode recovery
docker restart primary-broker-0
```

**For stopped broker:**
```bash
# Go-based yq (mikefarah/yq):
yq '.redpanda.recovery_mode_enabled = true' -i redpanda-config/primary-broker-0/redpanda.yaml

# Python-based yq (kislyuk/yq):
yq -y '.redpanda.recovery_mode_enabled = true' redpanda-config/primary-broker-0/redpanda.yaml > /tmp/temp.yaml && mv /tmp/temp.yaml redpanda-config/primary-broker-0/redpanda.yaml

docker start primary-broker-0
```

### Exiting Recovery Mode
```bash
docker exec -it primary-broker-0 rpk redpanda mode production
docker restart primary-broker-0
```

### Checking Recovery Mode Status
```bash
# Using rpk
docker exec -it primary-broker-0 rpk cluster health

# Using Admin API
curl http://localhost:9644/v1/brokers | jq '.[] | {node_id, recovery_mode_enabled}'
```