#!/bin/bash

echo "🔧 Setting up topics on both clusters..."

# Create topic on cluster A (primary)
echo "📝 Creating topic on cluster A..."
docker exec cluster-a-broker-1 rpk topic create failover-demo-topic \
    --partitions 3 \
    --replicas 1 \
    --brokers cluster-a-broker-1:9092

# Create topic on cluster B (secondary)
echo "📝 Creating topic on cluster B..."
docker exec cluster-b-broker-1 rpk topic create failover-demo-topic \
    --partitions 3 \
    --replicas 1 \
    --brokers cluster-b-broker-1:9092

echo "✅ Topics created on both clusters"

# Verify topics
echo "🔍 Verifying topics..."
echo "Cluster A topics:"
docker exec cluster-a-broker-1 rpk topic list --brokers cluster-a-broker-1:9092

echo "Cluster B topics:"
docker exec cluster-b-broker-1 rpk topic list --brokers cluster-b-broker-1:9092

echo "✅ Topics created on both clusters"

echo "💡 Note: Each cluster has independent data - no replication configured"
echo "   This demonstrates Envoy's routing capabilities during failover"

echo "✅ Setup complete!"