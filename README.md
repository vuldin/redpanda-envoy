# Redpanda Envoy Failover PoC

This PoC demonstrates how Envoy proxy can facilitate transparent failover between Redpanda clusters for clients, without requiring client configuration changes or restarts.

## Architecture

```
Client Application (connects to envoy:9092)
           ↓
    Envoy Proxy (TCP Load Balancer)
     ↓ (priority 0)        ↓ (priority 1)
Primary Cluster       Secondary Cluster
primary-broker-0       secondary-broker-0
```

## Key Features

- **Zero Client Changes**: Clients connect only to `envoy:9092`
- **Automatic Failover**: Envoy health checks detect failures and route to secondary cluster
- **TCP Load Balancing**: Works with any Kafka client (no HTTP requirements)
- **Priority-based Routing**: Primary cluster preferred when healthy
- **Independent Clusters**: Each cluster maintains its own data (demonstrates routing capabilities)

## Prerequisites

- Docker and Docker Compose
- `yq` - YAML processor for editing broker configurations
  - Either **Go-based yq** (mikefarah/yq) or **Python-based yq** (kislyuk/yq) works
  - Go-based: `brew install yq` (macOS) or `snap install yq` (Linux) or [download from releases](https://github.com/mikefarah/yq/releases)
  - Python-based: `pip install yq`
  - Check which one you have: `yq --version`
- (Linux only) `sudo` access for setting file permissions

## Quick Start - Recovery Mode Testing

This demo shows how Envoy's Schema Registry health checks prevent routing traffic to clusters in recovery mode.

1. **Start the demo environment:**
   ```bash
   ./failover-demo.sh start
   ```

2. **Start Envoy routing monitor in a separate terminal (keep this running):**
   ```bash
   ./failover-demo.sh routing
   ```

   This displays real-time cluster health and routing status. Keep it running while you continue through the remaining steps.

3. **Start producer in one terminal:**
   ```bash
   docker exec -it test-client bash /test-producer.sh
   ```

4. **Start consumer in another terminal:**
   ```bash
   docker exec -it test-client bash /test-consumer.sh
   ```

5. **Stop one broker in primary cluster (simulating broker failure):**
   ```bash
   docker stop primary-broker-0
   ```

   Watch the routing monitor - Envoy continues routing to primary cluster (2/3 brokers still healthy).

6. **Stop a second broker in primary cluster (simulating cluster failure):**
   ```bash
   docker stop primary-broker-1
   ```

   Watch the routing monitor - Envoy fails over to secondary cluster (only 1/3 primary brokers healthy).

7. **Restart last running broker in recovery mode:**
   ```bash
   docker exec -it primary-broker-2 rpk redpanda mode recovery
   docker restart primary-broker-2
   ```

8. **Verify the single remaining broker is now in recovery mode:**
   ```bash
   docker exec -it primary-broker-2 rpk cluster health
   ```

   Look for "Nodes in recovery mode: [2]" showing broker 2 is in recovery.

   Watch the routing monitor - Envoy continues routing to secondary because Schema Registry is disabled!

9. **Edit config and restart the two stopped brokers in recovery mode:**

   **If you have Go-based yq (mikefarah/yq):**
   ```bash
   yq '.redpanda.recovery_mode_enabled = true' -i redpanda-config/primary-broker-0/redpanda.yaml
   yq '.redpanda.recovery_mode_enabled = true' -i redpanda-config/primary-broker-1/redpanda.yaml
   docker start primary-broker-0 primary-broker-1
   ```

   **If you have Python-based yq (kislyuk/yq):**
   ```bash
   yq -y '.redpanda.recovery_mode_enabled = true' redpanda-config/primary-broker-0/redpanda.yaml > /tmp/temp0.yaml && mv /tmp/temp0.yaml redpanda-config/primary-broker-0/redpanda.yaml
   yq -y '.redpanda.recovery_mode_enabled = true' redpanda-config/primary-broker-1/redpanda.yaml > /tmp/temp1.yaml && mv /tmp/temp1.yaml redpanda-config/primary-broker-1/redpanda.yaml
   docker start primary-broker-0 primary-broker-1
   ```

10. **Verify all primary brokers are in recovery mode:**
    ```bash
    docker exec -it primary-broker-0 rpk cluster health
    ```

    Expected output showing cluster is healthy but all nodes are in recovery mode:
    ```
    CLUSTER HEALTH OVERVIEW
    =======================
    Healthy:                          true
    Unhealthy reasons:                []
    Controller ID:                    2
    All nodes:                        [0 1 2]
    Nodes down:                       []
    Nodes in recovery mode:           [0 1 2]
    Leaderless partitions (0):        []
    Under-replicated partitions (0):  []
    ```

    **Key observation**: The cluster reports as "Healthy: true" but all nodes show "Nodes in recovery mode: [0 1 2]".

    Watch the routing monitor - Envoy continues routing to secondary because Schema Registry is disabled in recovery mode!

11. **Take primary cluster out of recovery mode:**
    ```bash
    docker exec primary-broker-0 rpk redpanda mode dev
    docker restart primary-broker-0

    docker exec primary-broker-1 rpk redpanda mode dev
    docker restart primary-broker-1

    docker exec primary-broker-2 rpk redpanda mode dev
    docker restart primary-broker-2
    ```

    **Note**: The restart is required for the mode change to take effect. For production deployments, replace `dev` with `prod` or `production`.

    As each broker exits recovery mode and restarts, Schema Registry becomes available again. Once the last broker is taken out of recovery mode, Envoy will detect that the primary cluster is ready for connections and automatically begin routing traffic back to it.

12. **Verify Envoy starts routing traffic back to primary:**

    Watch the routing monitor - traffic automatically returns to primary cluster (priority 0) once all brokers are healthy and out of recovery mode!

## Files Overview

- `docker-compose.yml` - Complete environment setup with volume mounts for configs
- `redpanda-config/` - Directory containing individual redpanda.yaml files for each broker
- `envoy-proxy/envoy.yaml` - Envoy configuration with Schema Registry health checks
- `test-producer.sh` - RPK-based producer connecting via Envoy
- `test-consumer.sh` - RPK-based consumer connecting via Envoy
- `setup-topics.sh` - Creates demo topics on both clusters
- `failover-demo.sh` - Main demo orchestration script

## Configuration Structure

Each broker has its own configuration file:
```
redpanda-config/
├── primary-broker-0/redpanda.yaml
├── primary-broker-1/redpanda.yaml
├── primary-broker-2/redpanda.yaml
├── secondary-broker-0/redpanda.yaml
├── secondary-broker-1/redpanda.yaml
└── secondary-broker-2/redpanda.yaml
```

**Important (Linux only):** On Linux, these directories must be owned by UID/GID 101:101 (Redpanda user in container):
```bash
sudo chown -R 101:101 redpanda-config/
```

Docker Desktop on macOS and Windows handles volume permissions differently and typically doesn't require this step.

## Envoy Configuration Highlights

### TCP Proxy
- Listens on port 9092
- Routes all TCP traffic to Redpanda clusters
- Transparent to Kafka protocol

### Health Checking
- HTTP health checks to Schema Registry (`/schemas/types`) every 5 seconds
- Detects recovery mode (Schema Registry disabled)
- 3 failures mark endpoint unhealthy
- 30 second ejection time for failed endpoints

### Priority-based Load Balancing
- **Priority 0**: `primary-broker-0` (Primary)
- **Priority 1**: `secondary-broker-0` (Secondary)
- Traffic only goes to secondary when primary is unhealthy

### Outlier Detection
- Monitors connection failures
- Automatically ejects problematic endpoints
- 50% max ejection to maintain availability

## Testing Different Scenarios

### 1. Normal Operation
- Both clusters healthy
- All traffic routes to primary cluster
- Secondary cluster remains ready for failover

### 2. Primary Cluster Failure
- Primary unhealthy → Traffic automatically routes to secondary cluster
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

## How Recovery Mode Detection Works

Envoy detects recovery mode by checking Schema Registry (port 8081):

1. **Normal operation**: Schema Registry responds with HTTP 200 to `/schemas/types`
2. **Recovery mode**: Schema Registry is disabled → health check fails
3. **Failover**: Envoy marks broker unhealthy and routes to secondary cluster

Health check configuration per endpoint:
```yaml
endpoint:
  address:
    socket_address:
      address: primary-broker-0
      port_value: 9092              # Traffic goes here
  health_check_config:
    port_value: 8081                # Health checks go here
```

**Why Schema Registry?**
- Disabled in recovery mode (unlike Admin API on port 9644)
- Simple HTTP endpoint, no authentication required
- Lightweight check: `GET /schemas/types` returns `["JSON","PROTOBUF","AVRO"]`

## Production Considerations

1. **Data Replication**: Implement data sync between clusters (MirrorMaker, Redpanda Connect, etc.)
2. **Consumer Group Coordination**: Manage consumer offsets across clusters
3. **DNS/Service Discovery**: Replace container names with actual hostnames
4. **TLS Termination**: Add SSL/TLS support in Envoy configuration
5. **Authentication**: Configure SASL/SCRAM forwarding through Envoy
6. **Monitoring**: Integrate with Prometheus/Grafana for observability
7. **Application Logic**: Handle potential data inconsistencies during failover
8. **Health Check Tuning**: Adjust thresholds based on network conditions and recovery time objectives
9. **Config Management**: Use configuration management tools to maintain broker configs at scale

## Clean Up

```bash
./failover-demo.sh stop
```