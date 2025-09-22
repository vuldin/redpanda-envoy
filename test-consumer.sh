#!/bin/bash

echo "🚀 Starting RPK-based consumer test - connecting to envoy:9092"
echo "This consumer will continuously read messages to demonstrate failover"
echo "Press Ctrl+C to stop"
echo "=========================================="

# Flag to track if we should exit
should_exit=false

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

# Consumer with retry logic for better failover handling
first_run=true
while [ "$should_exit" = false ]; do
    if [ "$first_run" = true ]; then
        echo "🔄 Starting consumer..."
        first_run=false
    else
        echo "🔄 Restarting consumer..."
    fi

    rpk topic consume failover-demo-topic \
        --brokers envoy:9092 \
        --group failover-demo-group \
        --offset start \
        --fetch-max-wait 30s \
        --format 'Consumed from partition %p at offset %o with timestamp %T.
✅ Received message: %v' &

    # Get the PID of the background process
    rpk_pid=$!

    # Wait for the process to complete with timeout
    timeout 60 bash -c "wait $rpk_pid" 2>/dev/null
    wait_result=$?

    if [ $wait_result -eq 124 ]; then
        # Timeout occurred, kill the rpk process
        echo "⏰ Consumer hung, killing and restarting..."
        kill -9 $rpk_pid 2>/dev/null
        exit_code=1
    else
        # Get actual exit code
        wait $rpk_pid 2>/dev/null
        exit_code=$?
    fi

    # Check if we should exit due to signal
    if [ "$should_exit" = true ]; then
        break
    fi

    # Handle different exit codes
    if [ $exit_code -eq 0 ]; then
        echo "ℹ️  Consumer exited normally"
        break
    else
        echo "⚠️  Consumer timeout (no messages), restarting..."
        if [ "$should_exit" = false ]; then
            sleep 3
        fi
    fi
done

echo "👋 Consumer stopped"