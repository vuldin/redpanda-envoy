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
- **primary-broker-0**: Primary Redpanda cluster (port 19092 external)
- **secondary-broker-0**: Secondary Redpanda cluster (port 29092 external)
- **envoy-proxy**: TCP proxy listening on port 9092, routes to clusters with priority-based failover
- **migrator**: Redpanda Connect service for real-time replication from Primary → Secondary
- **test-client**: Container with RPK-based test scripts

### Configuration Files
- **docker-compose.yml**: Complete environment setup
- **envoy-proxy/envoy.yaml**: Envoy TCP proxy with health checks and priority routing
- **test-producer.sh**: RPK-based producer connecting via Envoy
- **test-consumer.sh**: RPK-based consumer with retry logic and proper signal handling
- **setup-topics.sh**: Creates topics on both clusters and verifies migrator status
- **failover-demo.sh**: Main orchestration script with multiple commands

## Important Configuration Details

### Envoy Priority-based Load Balancing
- Priority 0: primary-broker-0 (Primary) - preferred when healthy
- Priority 1: secondary-broker-0 (Secondary) - used when primary unhealthy
- Health checks every 5 seconds with TCP connectivity tests
- 30-second ejection time for failed endpoints

### Redpanda Connect Replication
- Replicates `failover-demo-topic` from Primary to Secondary
- Preserves message keys, partition information, and timestamps
- Does NOT replicate consumer group state or topic configurations
- Uses `kafka_franz` input/output connectors

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
- Health checks use `/dev/tcp` for connectivity testing (no nc or curl dependency)

### Redpanda Connect
- Uses `docker.redpanda.com/redpandadata/connect` image
- Command: `redpanda-connect run <config>`
- Config passed via environment variable with shell command approach
- Invalid fields like `exclude_prefixes` in metadata cause linting errors

### Test Client Issues
- Container uses `rpk` as entrypoint by default - must override with `/bin/bash`
- Consumer script needs proper signal handling to allow Ctrl+C exit
- No Python dependencies needed with RPK-based approach

## Networking
- All services on `redpanda-net` bridge network
- Client connections go through envoy:9092
- Internal cluster communication on standard ports
- External access: 19092 (Primary), 29092 (Secondary), 9901 (Envoy admin)

## Data Consistency
- Real-time replication ensures secondary cluster has same messages as primary
- Consumer group state is NOT replicated - may cause re-reading after failover
- Message order preserved within partitions
- Possible duplicate processing during cluster transitions

## Monitoring & Observability
- Envoy admin interface: http://localhost:9901
- Envoy stats show cluster health, connection counts, priority levels
- Migrator logs show replication status and message processing
- Custom health check scripts show container status and connectivity