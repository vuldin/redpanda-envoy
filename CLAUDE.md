# Redpanda Envoy Failover PoC - Context for Claude

## Project Overview

This is a Proof of Concept demonstrating how Envoy proxy can facilitate transparent failover between Redpanda clusters for clients, without requiring client configuration changes or restarts. The setup includes real-time data replication between clusters using Redpanda Connect (migrator).

## Architecture

```
Client Application (connects to envoy:9092)
           ↓
    Envoy Proxy (TCP Load Balancer)
     ↓ (priority 0)        ↓ (priority 1)
Primary Cluster       Secondary Cluster
primary-broker-0       secondary-broker-0
           ↓                      ↑
           └── Redpanda Migrator ─┘
              (Real-time Replication)
```

## Key Components

### Services in Docker Compose
- **primary-broker-0/1/2**: Primary Redpanda cluster (3 brokers)
- **secondary-broker-0/1/2**: Secondary Redpanda cluster (3 brokers)
- **envoy-proxy**: TCP proxy listening on port 9092, routes to clusters with priority-based failover
- **test-client**: Container with RPK-based test scripts

### Configuration Files
- **docker-compose.yml**: Complete environment setup with volume mounts
- **redpanda-config/[broker-name]/redpanda.yaml**: Individual broker configurations
- **envoy-proxy/envoy.yaml**: Envoy TCP proxy with Schema Registry health checks
- **test-producer.sh**: RPK-based producer connecting via Envoy
- **test-consumer.sh**: RPK-based consumer with retry logic and proper signal handling
- **setup-topics.sh**: Creates topics on both clusters
- **failover-demo.sh**: Main orchestration script with multiple commands

## Important Configuration Details

### Envoy Priority-based Load Balancing
- Priority 0: primary-broker-0/1/2 (Primary cluster) - preferred when healthy
- Priority 1: secondary-broker-0/1/2 (Secondary cluster) - used when primary unhealthy
- Health checks every 5 seconds via HTTP to Schema Registry (port 8081)
- Detects recovery mode: Schema Registry disabled → broker marked unhealthy
- 30-second ejection time for failed endpoints

### Schema Registry Health Check Strategy
- **Traffic endpoint**: Kafka API on port 9092
- **Health check endpoint**: Schema Registry on port 8081
- **Path**: `GET /schemas/types`
- **Recovery mode detection**: Schema Registry is disabled in recovery mode
- **Advantage**: Admin API (port 9644) stays available in recovery mode, but Schema Registry doesn't

### Redpanda Configuration
- Each broker uses a dedicated redpanda.yaml config file
- Configuration mounted as volume: `./redpanda-config/[broker-name]:/etc/redpanda`
- **Important (Linux only)**: Config directories must be owned by UID/GID 101:101 (redpanda user)
  - Docker Desktop on macOS/Windows handles permissions automatically
- Enable recovery mode by setting `recovery_mode_enabled: true` in the `redpanda:` section
  - Go-based yq: `yq '.redpanda.recovery_mode_enabled = true' -i redpanda-config/[broker]/redpanda.yaml`
  - Python-based yq: `yq -y '.redpanda.recovery_mode_enabled = true' file.yaml > temp.yaml && mv temp.yaml file.yaml`

### Test Client Container
- Uses Redpanda image with overridden entrypoint (`/bin/bash`)
- RPK-based scripts (no Python dependencies)
- Consumer script has proper signal handling for Ctrl+C
- Producer sends messages every 2 seconds with timestamps

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

# Run test clients
docker exec -it test-client bash /test-producer.sh
docker exec -it test-client bash /test-consumer.sh

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
- Schema Registry health checks require per-endpoint `health_check_config.port_value` override
- Health check port cannot be set globally - must be set per endpoint

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
- **Node IDs**: Use 0-based indexing (0, 1, 2) not 1-based

### Test Client Issues
- Container uses `rpk` as entrypoint by default - must override with `/bin/bash`
- Consumer script needs proper signal handling to allow Ctrl+C exit
- No Python dependencies needed with RPK-based approach

### Health Check Debugging
- Check Envoy cluster status: `curl localhost:9901/clusters | grep health_flags`
- Check Schema Registry: `curl http://localhost:18081/schemas/types`
- Check Admin API: `curl http://localhost:9644/v1/brokers | jq '.[] | {node_id, recovery_mode_enabled}'`

## Networking
- All services on `redpanda-net` bridge network
- Client connections go through envoy:9092
- Internal cluster communication on standard ports
- External access: 19092 (Primary), 29092 (Secondary), 9901 (Envoy admin)

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
- Schema Registry health on port 18081 (primary-broker-0), 18084 (primary-broker-1), 18086 (primary-broker-2)

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