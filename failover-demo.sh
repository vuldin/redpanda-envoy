#!/bin/bash

echo "🚀 Starting Redpanda Envoy Failover Demo"
echo "========================================"

# Function to check if containers are running
check_health() {
    echo "🔍 Checking cluster health..."

    # Check container status first
    echo "Container status:"
    docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "(cluster-a-broker-1|cluster-b-broker-1|envoy-proxy)"
    echo ""

    # Check Cluster A
    echo "Cluster A detailed status:"
    if docker exec cluster-a-broker-1 rpk cluster info --brokers cluster-a-broker-1:9092 2>/dev/null; then
        echo "✅ Cluster A healthy"
    else
        echo "❌ Cluster A unhealthy - checking logs..."
        docker logs cluster-a-broker-1 --tail 5
    fi
    echo ""

    # Check Cluster B
    echo "Cluster B detailed status:"
    if docker exec cluster-b-broker-1 rpk cluster info --brokers cluster-b-broker-1:9092 2>/dev/null; then
        echo "✅ Cluster B healthy"
    else
        echo "❌ Cluster B unhealthy - checking logs..."
        docker logs cluster-b-broker-1 --tail 5
    fi
    echo ""

    # Check Envoy status
    echo "Envoy container status:"
    if docker ps | grep -q envoy-proxy; then
        echo "✅ Envoy container is running"
        echo "Testing Envoy connectivity to clusters:"
        echo "Cluster A reachable from Envoy:"
        if timeout 3 docker exec envoy-proxy /bin/bash -c "echo > /dev/tcp/cluster-a-broker-1/9092" 2>/dev/null; then
            echo "✅ Reachable"
        else
            echo "❌ Unreachable"
        fi
        echo "Cluster B reachable from Envoy:"
        if timeout 3 docker exec envoy-proxy /bin/bash -c "echo > /dev/tcp/cluster-b-broker-1/9092" 2>/dev/null; then
            echo "✅ Reachable"
        else
            echo "❌ Unreachable"
        fi
    else
        echo "❌ Envoy container is not running - checking logs..."
        docker logs envoy-proxy --tail 10
    fi
    echo ""

    # Envoy cluster and routing stats
    echo "Envoy cluster and routing information:"
    echo "=== Cluster Health Status ==="
    curl -s http://localhost:9901/stats | grep -E "redpanda_cluster\.membership_(healthy|total)" | sort
    echo ""
    echo "=== Active Connections per Endpoint ==="
    curl -s http://localhost:9901/stats | grep -E "redpanda_cluster\.cluster-[ab]-broker-1.*cx_active" | sort
    echo ""
    echo "=== Health Check Status ==="
    curl -s http://localhost:9901/stats | grep -E "redpanda_cluster\.health_check\.(attempt|success|failure)" | sort
    echo ""
    echo "=== Priority Levels ==="
    curl -s http://localhost:9901/stats | grep -E "redpanda_cluster\.priority_[01]\." | head -6
    echo ""
}

# Function to show real-time routing information
show_routing_info() {
    echo "🔍 Starting continuous routing display (Press Ctrl+C to exit)"
    echo ""

    # Create a function that will be called by watch
    cat > /tmp/envoy_routing_display.sh << 'EOF'
#!/bin/bash
printf "\n🚀 ENVOY ROUTING STATUS\n"
printf "=====================\n\n"

printf "%-20s %-15s %-12s %-15s\n" "CLUSTER" "PRIORITY" "HEALTH" "ROUTING_STATUS"
printf "%-20s %-15s %-12s %-15s\n" "-------" "--------" "------" "--------------"

# Get cluster info and stats
clusters_output=$(curl -s http://localhost:9901/clusters 2>/dev/null)
stats_output=$(curl -s http://localhost:9901/stats 2>/dev/null)

# Parse cluster A info
cluster_a_health="UNKNOWN"
cluster_a_routing="NO"

if echo "$clusters_output" | grep -A 5 "cluster-a-broker-1" | grep -q "health_flags::healthy"; then
    cluster_a_health="HEALTHY"
    cluster_a_routing="YES"
elif echo "$clusters_output" | grep -A 5 "cluster-a-broker-1" | grep -q "health_flags"; then
    cluster_a_health="UNHEALTHY"
fi

# Connection logic removed - ROUTING_STATUS column provides sufficient information

# Parse cluster B info
cluster_b_health="UNKNOWN"
cluster_b_routing="NO"

if echo "$clusters_output" | grep -A 5 "cluster-b-broker-1" | grep -q "health_flags::healthy"; then
    cluster_b_health="HEALTHY"
    # Only route to cluster B if cluster A is unhealthy (priority routing)
    if [ "$cluster_a_health" != "HEALTHY" ]; then
        cluster_b_routing="YES"
    fi
elif echo "$clusters_output" | grep -A 5 "cluster-b-broker-1" | grep -q "health_flags"; then
    cluster_b_health="UNHEALTHY"
fi

# Connection logic removed - ROUTING_STATUS column provides sufficient information

# Display the table
printf "%-20s %-15s %-12s %-15s\n" "cluster-a-broker-1" "0 (Primary)" "$cluster_a_health" "$cluster_a_routing"
printf "%-20s %-15s %-12s %-15s\n" "cluster-b-broker-1" "1 (Secondary)" "$cluster_b_health" "$cluster_b_routing"

printf "\n💡 Priority routing: Traffic goes to Priority 0 first, then Priority 1 if Priority 0 is unhealthy\n"
EOF

    chmod +x /tmp/envoy_routing_display.sh

    # Use watch to continuously display the routing info
    watch -n 2 -t /tmp/envoy_routing_display.sh

    # Cleanup
    rm -f /tmp/envoy_routing_display.sh
}

# Function to simulate cluster failure
simulate_cluster_a_failure() {
    echo "💥 Simulating Cluster A failure (stopping cluster-a-broker-1)..."
    docker stop cluster-a-broker-1
    sleep 5
    echo "🔄 Envoy should now route to Cluster B"
    check_health
}

# Function to restore cluster
restore_cluster_a() {
    echo "🔄 Restoring Cluster A..."
    docker start cluster-a-broker-1
    sleep 10
    echo "✅ Cluster A restored - Envoy should detect and route back"
    check_health
}

# Function to simulate secondary cluster failure
simulate_cluster_b_failure() {
    echo "💥 Simulating Cluster B (secondary) failure (stopping cluster-b-broker-1)..."
    docker stop cluster-b-broker-1
    sleep 5
    echo "🔄 Cluster B is down - traffic should remain on Cluster A (no impact expected)"
    echo "⚠️  Note: Cluster B data is now independent from Cluster A"
    check_health
}

# Function to restore secondary cluster
restore_cluster_b() {
    echo "🔄 Restoring Cluster B..."
    docker start cluster-b-broker-1
    sleep 10
    echo "✅ Cluster B restored - available for failover again"
    check_health
}

# Main demo flow
case "$1" in
    "start")
        echo "▶️  Starting all services..."
        docker compose up -d
        echo "⏳ Waiting for services to become healthy (this may take up to 60 seconds)..."

        # Wait for health checks to pass
        timeout=60
        while [ $timeout -gt 0 ]; do
            healthy_count=$(docker compose ps --format table | grep -c "healthy" || true)
            if [ "$healthy_count" -ge 3 ]; then
                echo "✅ All services are healthy!"
                break
            fi
            echo "⏳ Still waiting... ($healthy_count/3 services healthy, $timeout seconds remaining)"
            sleep 10
            timeout=$((timeout-10))
        done

        if [ $timeout -le 0 ]; then
            echo "⚠️  Timeout waiting for services, but continuing with setup..."
            echo "Current service status:"
            docker compose ps
        fi

        ./setup-topics.sh
        check_health
        echo ""
        echo "🎯 Demo ready! Run the following in separate terminals:"
        echo ""
        echo "   # Start producer:"
        echo "   docker exec -it test-client bash /test-producer.sh"
        echo ""
        echo "   # Start consumer:"
        echo "   docker exec -it test-client bash /test-consumer.sh"
        echo ""
        echo "Then run: ./failover-demo.sh fail-primary"
        ;;

    "fail-primary")
        simulate_cluster_a_failure
        echo ""
        echo "💡 Notice: Clients continue working without config changes!"
        echo "   Run: ./failover-demo.sh restore-primary (to restore)"
        ;;

    "restore-primary")
        restore_cluster_a
        echo ""
        echo "💡 Notice: Traffic may shift back to primary cluster"
        ;;

    "fail-secondary")
        simulate_cluster_b_failure
        echo ""
        echo "💡 Notice: Clients should continue working normally (no failover needed)"
        echo "   Run: ./failover-demo.sh restore-secondary (to restore secondary cluster)"
        ;;

    "restore-secondary")
        restore_cluster_b
        echo ""
        echo "💡 Notice: Secondary cluster ready for potential failover"
        ;;

    "status")
        check_health
        ;;

    "routing")
        show_routing_info
        ;;


    "stop")
        echo "⏹️  Stopping all services..."
        docker compose down
        ;;

    *)
        echo "Usage: $0 {start|fail-primary|restore-primary|fail-secondary|restore-secondary|status|routing|stop}"
        echo ""
        echo "Commands:"
        echo "  start             - Start the complete demo environment"
        echo "  fail-primary      - Simulate primary cluster failure (triggers failover)"
        echo "  restore-primary   - Restore primary cluster"
        echo "  fail-secondary    - Simulate secondary cluster failure (no client impact)"
        echo "  restore-secondary - Restore secondary cluster"
        echo "  status            - Check cluster health and stats"
        echo "  routing           - Show detailed Envoy routing information"
        echo "  stop              - Stop all services"
        ;;
esac