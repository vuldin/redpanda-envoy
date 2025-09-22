# Redpanda Envoy Failover PoC

This PoC demonstrates how Envoy proxy can facilitate transparent failover between Redpanda clusters for clients, without requiring client configuration changes or restarts.

## Architecture

```
Client Application (connects to envoy:9092)
           ↓
    Envoy Proxy (TCP Load Balancer)
     ↓ (priority 0)        ↓ (priority 1)
Cluster A (Primary)    Cluster B (Secondary)
cluster-a-broker-1     cluster-b-broker-1
```

## Key Features

- **Zero Client Changes**: Clients connect only to `envoy:9092`
- **Automatic Failover**: Envoy health checks detect failures and route to secondary cluster
- **TCP Load Balancing**: Works with any Kafka client (no HTTP requirements)
- **Priority-based Routing**: Primary cluster preferred when healthy
- **Independent Clusters**: Each cluster maintains its own data (demonstrates routing capabilities)

## Quick Start

1. **Start the demo environment:**
   ```bash
   ./failover-demo.sh start
   ```

2. **Start producer in one terminal:**
   ```bash
   docker exec -it test-client bash /test-producer.sh
   ```

3. **Start consumer in another terminal:**
   ```bash
   docker exec -it test-client bash /test-consumer.sh
   ```

4. **Simulate primary cluster failure:**
   ```bash
   ./failover-demo.sh fail-primary
   ```

   Notice: Producer and consumer continue working without interruption!

5. **Restore primary cluster:**
   ```bash
   ./failover-demo.sh restore-primary
   ```

6. **Test secondary cluster failure (optional):**
   ```bash
   # This tests routing resilience - clients should be unaffected
   ./failover-demo.sh fail-secondary
   ./failover-demo.sh restore-secondary
   ```

7. **Check routing and health status:**
   ```bash
   ./failover-demo.sh status
   ./failover-demo.sh routing
   ```

## Files Overview

- `docker-compose.yml` - Complete environment setup
- `envoy-proxy/envoy.yaml` - Envoy configuration with health checks and priorities
- `test-producer.sh` - RPK-based producer connecting via Envoy
- `test-consumer.sh` - RPK-based consumer connecting via Envoy
- `setup-topics.sh` - Creates demo topics on both clusters
- `failover-demo.sh` - Main demo orchestration script

## Envoy Configuration Highlights

### TCP Proxy
- Listens on port 9092
- Routes all TCP traffic to Redpanda clusters
- Transparent to Kafka protocol

### Health Checking
- TCP health checks every 5 seconds
- 3 failures mark endpoint unhealthy
- 30 second ejection time for failed endpoints

### Priority-based Load Balancing
- **Priority 0**: `cluster-a-broker-1` (Primary)
- **Priority 1**: `cluster-b-broker-1` (Secondary)
- Traffic only goes to secondary when primary is unhealthy

### Outlier Detection
- Monitors connection failures
- Automatically ejects problematic endpoints
- 50% max ejection to maintain availability

## Testing Different Scenarios

### 1. Normal Operation
- Both clusters healthy
- All traffic routes to primary cluster (Cluster A)
- Secondary cluster (Cluster B) remains ready for failover

### 2. Primary Cluster Failure
- Primary unhealthy → Traffic automatically routes to secondary (Cluster B)
- Clients experience brief connection interruption during TCP failover
- New data written to secondary cluster

### 3. Primary Cluster Recovery
- Primary becomes healthy → Traffic gradually shifts back to primary
- Demonstrates Envoy's priority-based routing
- New data written to primary cluster (clusters have independent data)

### 4. Both Clusters Unhealthy
- Envoy returns connection errors to clients
- No healthy upstream available

## Monitoring

- **Envoy Admin**: http://localhost:9901
- **Cluster Stats**: `curl localhost:9901/stats | grep redpanda_cluster`
- **Health Check Stats**: `curl localhost:9901/stats | grep health_check`

## Client Configuration

Clients only need:
```python
bootstrap_servers=['envoy:9092']  # or localhost:9092 from host
```

No cluster-specific configuration required!

## Production Considerations

1. **Data Replication**: Implement data sync between clusters (MirrorMaker, Redpanda Connect, etc.)
2. **Consumer Group Coordination**: Manage consumer offsets across clusters
3. **DNS/Service Discovery**: Replace container names with actual hostnames
4. **TLS Termination**: Add SSL/TLS support in Envoy configuration
5. **Authentication**: Configure SASL/SCRAM forwarding through Envoy
6. **Monitoring**: Integrate with Prometheus/Grafana for observability
7. **Application Logic**: Handle potential data inconsistencies during failover

## Clean Up

```bash
./failover-demo.sh stop
```