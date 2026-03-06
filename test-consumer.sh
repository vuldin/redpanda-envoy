#!/bin/bash

echo "🚀 Starting RPK-based consumer test with failover support (TLS enabled)"
echo "This consumer will continuously read messages and handle broker failures"
echo "Brokers: envoy:9092,envoy:9093,envoy:9094 (with automatic failover)"
echo "TLS: Enabled (passthrough via Envoy, terminates at broker)"
echo "Press Ctrl+C to stop"
echo "=========================================="

# Flag to track if we should exit
should_exit=false
consecutive_failures=0
max_failures=3

# Signal handler for Ctrl+C
cleanup() {
    echo ""
    echo "🛑 Received interrupt signal, stopping consumer..."
    should_exit=true
    # Kill any running rpk process
    pkill -f "rpk topic consume" 2>/dev/null
    exit 0
}

# Set up signal trap
trap cleanup SIGINT SIGTERM

# Consumer with enhanced retry logic for failover handling
first_run=true
while [ "$should_exit" = false ]; do
    if [ "$first_run" = true ]; then
        echo "🔄 Starting consumer..."
        first_run=false
    else
        echo "🔄 Restarting consumer (attempt after $consecutive_failures failures)..."
    fi

    # Use timeout and enhanced error handling
    timeout 45 rpk topic consume failover-demo-topic \
        --brokers envoy:9092,envoy:9093,envoy:9094 \
        --tls-enabled --tls-truststore /certs/ca.crt \
        --group failover-demo-group \
        --offset start \
        --fetch-max-wait 10s \
        --format 'Consumed from partition %p at offset %o with timestamp %T.
✅ Received message: %v' 2>/dev/null

    exit_code=$?

    # Check if we should exit due to signal
    if [ "$should_exit" = true ]; then
        break
    fi

    # Handle different exit codes and implement progressive backoff
    if [ $exit_code -eq 0 ]; then
        echo "ℹ️  Consumer exited normally"
        consecutive_failures=0
    elif [ $exit_code -eq 124 ]; then
        # Timeout - this is expected during normal operation when no messages
        echo "⏰ Consumer timeout (no new messages) - continuing..."
        consecutive_failures=0
        sleep 2
    else
        # Connection error or other failure
        consecutive_failures=$((consecutive_failures + 1))
        echo "❌ Consumer failed with exit code $exit_code (failure $consecutive_failures/$max_failures)"

        if [ $consecutive_failures -ge $max_failures ]; then
            echo "⚠️  Multiple consumer failures - waiting 15 seconds for failover to complete..."
            sleep 15
            consecutive_failures=0
        else
            echo "🔄 Retrying in 5 seconds..."
            sleep 5
        fi
    fi
done

echo "👋 Consumer stopped"