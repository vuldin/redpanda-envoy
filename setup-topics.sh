#!/bin/bash

echo "🔧 Setting up topics on both clusters..."

# Use the plaintext local listener (port 9091) for rpk commands inside broker containers.
# Port 9092 has TLS enabled and is used by external clients through Envoy.

# Create topic on primary cluster
echo "📝 Creating topic on primary cluster..."
docker exec primary-broker-0 rpk topic create failover-demo-topic \
    --partitions 3 \
    --replicas 3 \
    --brokers primary-broker-0:9091,primary-broker-1:9091,primary-broker-2:9091,primary-broker-3:9091,primary-broker-4:9091

# Create topic on secondary cluster
echo "📝 Creating topic on secondary cluster..."
docker exec secondary-broker-0 rpk topic create failover-demo-topic \
    --partitions 3 \
    --replicas 3 \
    --brokers secondary-broker-0:9091,secondary-broker-1:9091,secondary-broker-2:9091

echo "✅ Topics created on both clusters"

# Verify topics
echo "🔍 Verifying topics..."
echo "Primary cluster topics:"
docker exec primary-broker-0 rpk topic list --brokers primary-broker-0:9091,primary-broker-1:9091,primary-broker-2:9091,primary-broker-3:9091,primary-broker-4:9091

echo "Secondary cluster topics:"
docker exec secondary-broker-0 rpk topic list --brokers secondary-broker-0:9091,secondary-broker-1:9091,secondary-broker-2:9091

echo "✅ Topics created on both clusters"

echo "💡 Note: Each cluster has independent data - no replication configured"
echo "   This demonstrates Envoy's routing capabilities during failover"

echo "✅ Setup complete!"
