# NotLeaderForPartitionError handling strategies

## Problem

When using Envoy for failover between independent Redpanda clusters (no data replication), clients hit `NotLeaderForPartitionError` during failover because:

1. Primary and secondary clusters have different partition assignments
2. Clients cache metadata about partition leadership from the primary
3. After failover, cached metadata points to wrong partitions on secondary
4. Secondary brokers reject requests: "I don't have that partition"

**From KAFKA_PROXYING_INVESTIGATION.md**: This is expected behavior when clusters are independent without data replication.

---

## Strategies (without data replication)

### Strategy 1: Faster metadata refresh (recommended)

Configure clients to refresh metadata more aggressively and handle errors gracefully.

**Current Implementation** (python-producer.py:28):
```python
metadata_max_age_ms=5000  # Refresh every 5 seconds
```

**Improvements**:

**For Producers** (python-producer.py):
```python
def create_producer():
    return KafkaProducer(
        bootstrap_servers=[KAFKA_BROKER],

        # Aggressive metadata refresh
        metadata_max_age_ms=3000,          # Refresh every 3s instead of 5s

        # Fail fast to trigger metadata refresh sooner
        request_timeout_ms=8000,           # Reduced from 10s to 8s
        max_block_ms=10000,                # Reduced from 15s to 10s

        # More retries with faster backoff
        retries=20,                        # Increased from 10
        retry_backoff_ms=200,              # Reduced from 500ms

        # Connection management
        connections_max_idle_ms=15000,     # Must be larger than request_timeout_ms
        reconnect_backoff_ms=100,          # Faster reconnection (from 250ms)
        reconnect_backoff_max_ms=1000,     # Lower max backoff (from 2s)
    )
```

**For Consumers** (python-consumer.py):
```python
def create_consumer():
    return KafkaConsumer(
        TOPIC,
        bootstrap_servers=[KAFKA_BROKER],

        # Aggressive metadata refresh
        metadata_max_age_ms=3000,          # Refresh every 3s instead of 5s

        # Fail fast settings
        request_timeout_ms=15000,          # Reduced from 20s
        session_timeout_ms=10000,          # Reduced from 12s (must be < request_timeout)
        heartbeat_interval_ms=3000,        # Reduced from 4s (must be < session_timeout)

        # Connection management
        connections_max_idle_ms=20000,     # Must be larger than request_timeout_ms
        reconnect_backoff_ms=100,          # Faster reconnection
        reconnect_backoff_max_ms=1000,     # Lower max backoff

        # Reduce max poll interval to fail faster
        max_poll_interval_ms=20000,        # Reduced from 30s
    )
```

**Pros:**
- Clients find the secondary cluster faster (3s metadata refresh)
- Faster failure detection (lower timeouts)
- Better retry behavior
- No application code changes

**Limitations:**
- Still 3-10 seconds of errors during failover
- Data on primary is lost (not on secondary)
- Consumer groups don't preserve offsets across clusters

**What actually happens:**
1. Failover happens (primary → secondary)
2. Client tries cached partition → NotLeaderForPartitionError (2-3 attempts)
3. Metadata refreshes → client discovers secondary topology
4. Client starts producing/consuming to secondary cluster's partitions
5. **Data loss**: Messages on primary are NOT on secondary

---

### Strategy 2: Application-level error handling

Handle NotLeaderForPartitionError explicitly in your code and degrade gracefully.

**Producer with failover handling:**

```python
#!/usr/bin/env python3
"""
Failover-aware Kafka Producer with NotLeaderForPartitionError handling
"""

import time
import sys
from datetime import datetime
from kafka import KafkaProducer
from kafka.errors import (
    KafkaError,
    NotLeaderForPartitionError,
    LeaderNotAvailableError,
    KafkaTimeoutError,
    RequestTimedOutError
)

KAFKA_BROKER = 'envoy:9092'
TOPIC = 'failover-demo-topic'
MESSAGE_INTERVAL = 2

# Failover detection state
failover_detected = False
error_count = 0
ERROR_THRESHOLD = 3  # Declare failover after 3 consecutive errors

def create_producer():
    return KafkaProducer(
        bootstrap_servers=[KAFKA_BROKER],
        client_id='failover-aware-producer',
        acks='all',
        retries=20,
        retry_backoff_ms=200,
        request_timeout_ms=8000,
        max_block_ms=10000,
        metadata_max_age_ms=3000,
        connections_max_idle_ms=15000,
        reconnect_backoff_ms=100,
        reconnect_backoff_max_ms=1000,
        value_serializer=lambda v: v.encode('utf-8'),
        key_serializer=lambda k: k.encode('utf-8') if k else None
    )

def handle_failover_error(error, message_count):
    """Detect and handle potential failover scenarios"""
    global failover_detected, error_count

    # Check if error indicates potential failover
    failover_errors = (
        NotLeaderForPartitionError,
        LeaderNotAvailableError,
        RequestTimedOutError
    )

    if isinstance(error, failover_errors):
        error_count += 1
        timestamp = datetime.now().strftime('%H:%M:%S')

        if error_count >= ERROR_THRESHOLD and not failover_detected:
            failover_detected = True
            print(f'⚠️  [{timestamp}] FAILOVER DETECTED - {error_count} consecutive errors')
            print(f'   Waiting for cluster recovery and metadata refresh...')
            # Give Envoy time to detect failure and route to secondary
            time.sleep(5)  # Wait for health checks + metadata refresh
            return True  # Signal to force metadata refresh
        else:
            print(f'⚠️  [{timestamp}] Potential failover error ({error_count}/{ERROR_THRESHOLD}): {type(error).__name__}')
    else:
        # Reset counter for non-failover errors
        error_count = 0

    return False

def main():
    global failover_detected, error_count

    print(f'🚀 Starting Failover-Aware Kafka Producer')
    print(f'📡 Connecting to: {KAFKA_BROKER}')
    print(f'📝 Topic: {TOPIC}')
    print(f'─' * 60)

    producer = create_producer()
    message_count = 0

    try:
        while True:
            message_count += 1
            timestamp = datetime.now().isoformat()
            message = f'Message {message_count} at {timestamp}'

            try:
                future = producer.send(
                    TOPIC,
                    key=f'key-{message_count}',
                    value=message
                )

                record_metadata = future.get(timeout=10)

                # Success - reset error tracking
                if failover_detected or error_count > 0:
                    print(f'✅ [{datetime.now().strftime("%H:%M:%S")}] RECOVERY COMPLETE - Producer operational')
                    failover_detected = False
                    error_count = 0

                timestamp_str = datetime.now().strftime('%H:%M:%S')
                print(f'✓ [{timestamp_str}] Message {message_count} delivered to partition [{record_metadata.partition}] at offset {record_metadata.offset}')

            except KafkaError as e:
                should_recreate = handle_failover_error(e, message_count)

                if should_recreate:
                    # Recreate producer to force fresh metadata
                    print(f'🔄 Recreating producer to force metadata refresh...')
                    producer.close(timeout=2)
                    time.sleep(2)
                    producer = create_producer()
                    # Don't increment message_count, retry this message
                    message_count -= 1
                else:
                    print(f'❌ [{datetime.now().strftime("%H:%M:%S")}] Error producing message {message_count}: {e}')

            time.sleep(MESSAGE_INTERVAL)

    except KeyboardInterrupt:
        print(f'\n⏹️  Shutting down producer...')
    finally:
        producer.flush(timeout=10)
        producer.close()
        print(f'✅ Producer stopped. Total messages: {message_count}')

if __name__ == '__main__':
    main()
```

**Consumer with failover handling:**

```python
#!/usr/bin/env python3
"""
Failover-aware Kafka Consumer with NotLeaderForPartitionError handling
"""

import sys
import time
from datetime import datetime
from kafka import KafkaConsumer
from kafka.errors import (
    KafkaError,
    CommitFailedError,
    RequestTimedOutError,
    NoBrokersAvailable
)

KAFKA_BROKER = 'envoy:9092'
TOPIC = 'failover-demo-topic'
GROUP_ID = 'failover-aware-consumer-group'

# Failover detection
consecutive_errors = 0
ERROR_THRESHOLD = 3

def create_consumer():
    return KafkaConsumer(
        TOPIC,
        bootstrap_servers=[KAFKA_BROKER],
        client_id='failover-aware-consumer',
        group_id=GROUP_ID,
        auto_offset_reset='earliest',
        enable_auto_commit=True,
        auto_commit_interval_ms=3000,  # More frequent commits
        session_timeout_ms=10000,
        heartbeat_interval_ms=3000,
        request_timeout_ms=15000,
        max_poll_interval_ms=20000,
        metadata_max_age_ms=3000,
        connections_max_idle_ms=20000,
        reconnect_backoff_ms=100,
        reconnect_backoff_max_ms=1000,
        consumer_timeout_ms=5000,  # Return from poll after 5s if no messages
        value_deserializer=lambda m: m.decode('utf-8'),
        key_deserializer=lambda k: k.decode('utf-8') if k else None
    )

def main():
    global consecutive_errors

    print(f'🚀 Starting Failover-Aware Kafka Consumer')
    print(f'📡 Connecting to: {KAFKA_BROKER}')
    print(f'📝 Topic: {TOPIC}')
    print(f'👥 Consumer Group: {GROUP_ID}')
    print(f'─' * 60)

    consumer = create_consumer()
    message_count = 0
    failover_mode = False

    try:
        print('⏳ Waiting for messages...\n')

        while True:
            try:
                # Poll with timeout
                messages = consumer.poll(timeout_ms=5000, max_records=10)

                if messages:
                    # Reset error counter on successful poll
                    if consecutive_errors > 0:
                        print(f'✅ [{datetime.now().strftime("%H:%M:%S")}] RECOVERY COMPLETE - Consumer operational')
                        consecutive_errors = 0
                        failover_mode = False

                    for topic_partition, records in messages.items():
                        for message in records:
                            message_count += 1
                            timestamp = datetime.now().strftime('%H:%M:%S')

                            print(f'✓ [{timestamp}] Received message {message_count}')
                            print(f'  Partition: {message.partition}')
                            print(f'  Offset: {message.offset}')
                            print(f'  Key: {message.key}')
                            print(f'  Value: {message.value}')
                            print()

                elif failover_mode:
                    # In failover mode but no messages - waiting for recovery
                    print(f'⏳ [{datetime.now().strftime("%H:%M:%S")}] Waiting for cluster recovery...')

            except (RequestTimedOutError, CommitFailedError, NoBrokersAvailable) as e:
                consecutive_errors += 1
                timestamp = datetime.now().strftime('%H:%M:%S')

                if consecutive_errors >= ERROR_THRESHOLD and not failover_mode:
                    failover_mode = True
                    print(f'⚠️  [{timestamp}] FAILOVER DETECTED - {consecutive_errors} consecutive errors')
                    print(f'   Recreating consumer to force metadata refresh...')
                    consumer.close()
                    time.sleep(5)  # Wait for Envoy health checks
                    consumer = create_consumer()
                    consecutive_errors = 0
                else:
                    print(f'⚠️  [{timestamp}] Consumer error ({consecutive_errors}/{ERROR_THRESHOLD}): {type(e).__name__}')

            except KafkaError as e:
                print(f'❌ Consumer error: {e}', file=sys.stderr)
                consecutive_errors += 1

    except KeyboardInterrupt:
        print(f'\n⏹️  Shutting down consumer...')
    finally:
        consumer.close()
        print(f'✅ Consumer stopped. Total messages consumed: {message_count}')

if __name__ == '__main__':
    main()
```

**Pros:**
- Application is aware of failover events
- Can add logging, alerting, or custom recovery logic
- More predictable behavior during failover

**Cons:**
- Requires app code changes
- More complex to maintain
- Still can't recover data from primary cluster

---

### Strategy 3: Topic namespacing per cluster

Use different topic names for each cluster to avoid partition conflicts.

**Implementation**:

**Setup Topics**:
```bash
# Primary cluster topics with prefix
rpk topic create primary-failover-demo-topic --brokers primary-broker-0:9092

# Secondary cluster topics with prefix
rpk topic create secondary-failover-demo-topic --brokers secondary-broker-0:9092
```

**Producer Logic**:
```python
def get_active_topic():
    """Determine which cluster is active based on metadata"""
    try:
        # Try to get metadata for primary topic
        producer = KafkaProducer(bootstrap_servers=['envoy:9092'])
        metadata = producer.partitions_for('primary-failover-demo-topic')
        producer.close()

        if metadata:
            return 'primary-failover-demo-topic'
        else:
            return 'secondary-failover-demo-topic'
    except:
        return 'secondary-failover-demo-topic'

# In main loop
active_topic = get_active_topic()
producer.send(active_topic, value=message)
```

**Pros:**
- No NotLeaderForPartitionError -- topics are cluster-specific
- Clear data separation per cluster

**Cons:**
- Requires application changes to select topics
- Consumers need to subscribe to both topics
- Fragments data across topics
- Doesn't solve the data availability problem

---

### Strategy 4: Circuit breaker with health checks

Monitor Envoy cluster health and proactively handle failover.

**Implementation**:

```python
#!/usr/bin/env python3
"""
Circuit Breaker Pattern for Kafka Failover
Monitors Envoy health and adapts producer behavior
"""

import time
import requests
from datetime import datetime
from kafka import KafkaProducer
from kafka.errors import KafkaError

ENVOY_ADMIN = 'http://envoy:9901'
KAFKA_BROKER = 'envoy:9092'

class CircuitBreaker:
    """Monitor Envoy health and track circuit state"""

    CLOSED = 'CLOSED'      # Normal operation
    OPEN = 'OPEN'          # Failover detected, prevent requests
    HALF_OPEN = 'HALF_OPEN'  # Testing if recovered

    def __init__(self):
        self.state = self.CLOSED
        self.failure_count = 0
        self.failure_threshold = 3
        self.recovery_timeout = 10  # seconds
        self.last_failure_time = None
        self.active_cluster = 'primary'

    def check_envoy_health(self):
        """Query Envoy admin interface for cluster health"""
        try:
            response = requests.get(f'{ENVOY_ADMIN}/clusters', timeout=2)
            clusters_info = response.text

            # Count healthy primary brokers
            primary_healthy = clusters_info.count('primary-broker') - clusters_info.count('health_flags::/failed')

            return primary_healthy >= 2  # At least 2 of 3 brokers healthy
        except:
            return False

    def record_failure(self):
        """Record a failure and potentially open circuit"""
        self.failure_count += 1
        self.last_failure_time = time.time()

        if self.failure_count >= self.failure_threshold:
            self.state = self.OPEN
            self.active_cluster = 'secondary'
            print(f'🔴 CIRCUIT OPEN - Failover to secondary cluster')
            return True
        return False

    def record_success(self):
        """Record success and potentially close circuit"""
        self.failure_count = 0

        if self.state == self.HALF_OPEN:
            self.state = self.CLOSED
            self.active_cluster = 'primary'
            print(f'🟢 CIRCUIT CLOSED - Primary cluster recovered')

    def attempt_recovery(self):
        """Try to recover from OPEN state"""
        if self.state == self.OPEN:
            elapsed = time.time() - self.last_failure_time
            if elapsed >= self.recovery_timeout:
                if self.check_envoy_health():
                    self.state = self.HALF_OPEN
                    print(f'🟡 CIRCUIT HALF-OPEN - Testing primary recovery')
                    return True
        return False

    def should_allow_request(self):
        """Determine if request should proceed"""
        self.attempt_recovery()
        return self.state in [self.CLOSED, self.HALF_OPEN]

def create_producer():
    return KafkaProducer(
        bootstrap_servers=[KAFKA_BROKER],
        client_id='circuit-breaker-producer',
        acks='all',
        retries=5,  # Fewer retries with circuit breaker
        retry_backoff_ms=200,
        request_timeout_ms=8000,
        max_block_ms=10000,
        metadata_max_age_ms=3000,
        value_serializer=lambda v: v.encode('utf-8'),
    )

def main():
    circuit = CircuitBreaker()
    producer = create_producer()
    message_count = 0

    print('🚀 Starting Circuit Breaker Kafka Producer')
    print('📡 Monitoring Envoy health and cluster state')
    print('─' * 60)

    try:
        while True:
            message_count += 1

            # Check circuit breaker before attempting send
            if not circuit.should_allow_request() and circuit.state == circuit.OPEN:
                print(f'⏸️  [{datetime.now().strftime("%H:%M:%S")}] Circuit OPEN - Waiting for recovery ({circuit.recovery_timeout}s)')
                time.sleep(1)
                continue

            try:
                message = f'Message {message_count} from {circuit.active_cluster}'
                future = producer.send('failover-demo-topic', value=message)
                record = future.get(timeout=10)

                circuit.record_success()

                timestamp = datetime.now().strftime('%H:%M:%S')
                cluster_indicator = '🟢' if circuit.active_cluster == 'primary' else '🔵'
                print(f'{cluster_indicator} [{timestamp}] Message {message_count} delivered '
                      f'(partition {record.partition}, offset {record.offset}) '
                      f'via {circuit.active_cluster}')

            except KafkaError as e:
                if circuit.record_failure():
                    # Circuit opened, recreate producer for fresh metadata
                    producer.close()
                    time.sleep(5)
                    producer = create_producer()
                else:
                    print(f'⚠️  Error ({circuit.failure_count}/{circuit.failure_threshold}): {e}')

            time.sleep(2)

    except KeyboardInterrupt:
        print('\n⏹️  Shutting down...')
    finally:
        producer.close()

if __name__ == '__main__':
    main()
```

**Pros:**
- Proactive detection of cluster issues
- Less error spam during failover
- Visibility into cluster state

**Cons:**
- Requires access to Envoy admin interface
- More complex to implement
- Adds latency for health checks

---

### Strategy 5: Read-only fallback

When failover occurs, switch to read-only mode and only consume existing data. Useful when the secondary has historical data but shouldn't accept new writes.

**Implementation**:
```python
class FailoverAwareApplication:
    def __init__(self):
        self.mode = 'READ_WRITE'  # or 'READ_ONLY'
        self.producer = None
        self.consumer = create_consumer()

    def detect_failover(self, error):
        """On failover, switch to read-only mode"""
        if isinstance(error, NotLeaderForPartitionError):
            print('⚠️ Failover detected - switching to READ-ONLY mode')
            self.mode = 'READ_ONLY'
            if self.producer:
                self.producer.close()
                self.producer = None
            return True
        return False

    def try_enable_writes(self):
        """Periodically check if writes can be enabled"""
        if self.mode == 'READ_ONLY':
            try:
                self.producer = create_producer()
                # Test produce
                future = self.producer.send('test-topic', value='health-check')
                future.get(timeout=5)
                self.mode = 'READ_WRITE'
                print('✅ Writes re-enabled - primary cluster recovered')
            except:
                pass

    def produce(self, message):
        """Produce only if in READ_WRITE mode"""
        if self.mode == 'READ_ONLY':
            print('⏸️ Skipping produce - in READ-ONLY mode')
            return False

        try:
            self.producer.send('topic', value=message)
            return True
        except KafkaError as e:
            self.detect_failover(e)
            return False
```

**Pros:**
- Prevents data loss from writing to secondary
- Application keeps read access

**Cons:**
- Application must handle read-only state
- Not suitable for all use cases
- Requires application changes

---

## Comparison

| Strategy | Complexity | Recovery time | Data safety | App changes | Best for |
|----------|-----------|---------------|-------------|-------------|----------|
| Faster metadata refresh | Low | 3-10s | Data loss | Minimal | Quick win, testing |
| App-level error handling | Medium | 5-15s | Data loss | Yes | Production apps |
| Topic namespacing | Medium | Immediate | Fragmented | Yes | Multi-tenant scenarios |
| Circuit breaker | High | 5-20s | Data loss | Yes | High-availability apps |
| Read-only fallback | Medium | Manual | Prevents loss | Yes | Read-heavy workloads |

None of these strategies solve the data availability problem. Data written to primary is not available on secondary without replication.

---

## Recommended approach: combine strategies

In practice, you'd layer these:

1. **Start with client config** (low effort) -- 3s metadata refresh, 8-10s request timeout, 20 retries with 200ms backoff
2. **Add app-level detection** -- track consecutive NotLeaderForPartitionError, recreate producer/consumer on failover, log events
3. **Add a circuit breaker** -- monitor Envoy health via admin interface, detect failover proactively, degrade gracefully
4. **Add monitoring** -- track error rates, alert on failover events, dashboard for active cluster

See Strategy 4 for a circuit breaker implementation that combines health monitoring with error detection.

---

## Long-term fix: data replication

The strategies above handle the errors, but they don't fix the underlying data availability problem. For production HA, add replication:

1. **Redpanda Remote Read Replicas** -- native feature, automatic sync, read-only secondary with promotion
2. **MirrorMaker 2.0** -- Kafka-native, active-passive or active-active, consumer group offset replication
3. **Redpanda Connect** -- streaming pipelines with custom transformations and multi-cluster sync

With replication, NotLeaderForPartitionError goes away (same partitions exist on both clusters), data is available on secondary, consumers pick up from their last offset, and failover is transparent.

---

## Testing failover handling

### Test scenario 1: Gradual primary failure
```bash
# Terminal 1: Start producer with error handling
docker exec -it python-client python3 python-producer-enhanced.py

# Terminal 2: Monitor Envoy routing
./failover-demo.sh routing

# Terminal 3: Simulate failure
docker stop primary-broker-0
sleep 15
docker stop primary-broker-1  # Triggers failover

# Observe: Producer detects failover, refreshes metadata, continues on secondary
```

### Test scenario 2: Recovery mode detection
```bash
# Put all primary brokers in recovery mode
for broker in primary-broker-{0..2}; do
    docker exec -it $broker rpk redpanda mode recovery
    docker restart $broker
done

# Observe: Envoy health checks fail, routes to secondary, producer continues
```

### Test scenario 3: Primary recovery
```bash
# Exit recovery mode
for broker in primary-broker-{0..2}; do
    docker exec -it $broker rpk redpanda mode dev
    docker restart $broker
done

# Observe: Envoy detects healthy primary, routes back, producer follows
```

---

## Monitoring

### Metrics to track

1. **NotLeaderForPartitionError rate**
   ```python
   notleader_errors_total.labels(cluster='primary').inc()
   ```

2. **Metadata refresh count**
   ```python
   metadata_refresh_total.inc()
   ```

3. **Active cluster indicator**
   ```python
   active_cluster.labels(cluster='secondary').set(1)
   ```

4. **Failover events**
   ```python
   failover_events_total.inc()
   ```

5. **Message success/failure rates**
   ```python
   messages_sent_total.labels(status='success', cluster='primary').inc()
   ```

### Envoy health check monitoring

```bash
# Check cluster health status
curl localhost:9901/clusters | grep -E "(primary-broker|secondary-broker|health_flags)"

# Check active connections
curl localhost:9901/stats | grep "cluster.broker_.*cluster.upstream_cx_active"

# Check priority-based routing
curl localhost:9901/stats | grep "priority"
```

---

## Summary

Without data replication, the best you can do is:

1. Faster metadata refresh (3s) -- immediate benefit, no code changes
2. Application-level error detection -- track consecutive errors, recreate clients
3. Circuit breaker -- monitor Envoy health, detect failover proactively
4. Monitoring -- track errors, failover events, cluster state

These minimize impact but don't prevent:
- Data on primary being unavailable during failover
- Consumer group state loss across clusters
- 3-15 seconds of disruption during failover

For production HA, add data replication (Remote Read Replicas, MirrorMaker 2, or Redpanda Connect).
