#!/bin/bash

echo "🚀 Starting RPK-based producer test - connecting to envoy:9092"
echo "This producer will continuously send messages to demonstrate failover"
echo "Press Ctrl+C to stop"
echo "=========================================="

message_count=0

while true; do
    timestamp=$(date +%s)
    message="Test message $message_count from failover demo - timestamp: $timestamp"

    if echo "$message" | rpk topic produce failover-demo-topic --brokers envoy:9092 2>/dev/null; then
        echo "✅ Sent message: $message"
    else
        echo "❌ Failed to send message $message_count"
    fi

    message_count=$((message_count + 1))
    sleep 2
done