#!/usr/bin/env python3
"""
Health aggregator for cluster-wide majority-based failover.

Checks all brokers in each cluster and returns:
- HTTP 200 if a majority of brokers are healthy (quorum intact)
- HTTP 503 if a majority of brokers are unhealthy (quorum lost)

Port 8080: Primary cluster health (3/5 majority required)
Port 8082: Secondary cluster health (2/3 majority required)
"""

import json
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import urlopen
from urllib.error import URLError

PRIMARY_BROKERS = [f"primary-broker-{i}" for i in range(5)]
SECONDARY_BROKERS = [f"secondary-broker-{i}" for i in range(3)]
PRIMARY_MAJORITY = 3   # 3 out of 5
SECONDARY_MAJORITY = 2 # 2 out of 3
CHECK_INTERVAL = 2     # seconds

# Shared state protected by lock
lock = threading.Lock()
primary_status = {}   # broker_name -> bool
secondary_status = {} # broker_name -> bool


def check_broker(broker, port=8081, timeout=2):
    """Check if a broker's Schema Registry is responding."""
    try:
        resp = urlopen(f"http://{broker}:{port}/schemas/types", timeout=timeout)
        return resp.status == 200
    except (URLError, OSError, Exception):
        return False


def health_check_loop():
    """Background thread that continuously checks all brokers."""
    while True:
        p_results = {}
        s_results = {}

        for broker in PRIMARY_BROKERS:
            p_results[broker] = check_broker(broker)
        for broker in SECONDARY_BROKERS:
            s_results[broker] = check_broker(broker)

        with lock:
            primary_status.update(p_results)
            secondary_status.update(s_results)

        time.sleep(CHECK_INTERVAL)


def make_handler(cluster_name, status_dict, majority_threshold):
    """Create a request handler for a specific cluster."""

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            with lock:
                statuses = dict(status_dict)

            healthy_count = sum(1 for v in statuses.values() if v)
            has_quorum = healthy_count >= majority_threshold

            if self.path == "/status":
                body = json.dumps({
                    "cluster": cluster_name,
                    "has_quorum": has_quorum,
                    "healthy_count": healthy_count,
                    "total": len(statuses),
                    "majority_threshold": majority_threshold,
                    "brokers": {k: "healthy" if v else "unhealthy" for k, v in statuses.items()},
                })
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body.encode())
                return

            # Default path: /schemas/types (matches Envoy health check path)
            if has_quorum:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'["JSON","PROTOBUF","AVRO"]')
            else:
                self.send_response(503)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                body = json.dumps({
                    "error": f"{cluster_name} cluster lost quorum",
                    "healthy": healthy_count,
                    "required": majority_threshold,
                })
                self.wfile.write(body.encode())

        def log_message(self, format, *args):
            # Suppress per-request logs to reduce noise (Envoy checks every 3s)
            pass

    return Handler


def main():
    # Start background health checker
    checker = threading.Thread(target=health_check_loop, daemon=True)
    checker.start()

    # Wait briefly for first health check round
    time.sleep(3)

    primary_handler = make_handler("primary", primary_status, PRIMARY_MAJORITY)
    secondary_handler = make_handler("secondary", secondary_status, SECONDARY_MAJORITY)

    primary_server = HTTPServer(("0.0.0.0", 8080), primary_handler)
    secondary_server = HTTPServer(("0.0.0.0", 8082), secondary_handler)

    primary_thread = threading.Thread(target=primary_server.serve_forever, daemon=True)
    secondary_thread = threading.Thread(target=secondary_server.serve_forever, daemon=True)

    primary_thread.start()
    secondary_thread.start()

    print(f"Health aggregator running:")
    print(f"  Port 8080: Primary cluster health ({PRIMARY_MAJORITY}/{len(PRIMARY_BROKERS)} majority)")
    print(f"  Port 8082: Secondary cluster health ({SECONDARY_MAJORITY}/{len(SECONDARY_BROKERS)} majority)")
    print(f"  Checking brokers every {CHECK_INTERVAL}s")

    # Keep main thread alive
    try:
        while True:
            time.sleep(60)
            with lock:
                p_healthy = sum(1 for v in primary_status.values() if v)
                s_healthy = sum(1 for v in secondary_status.values() if v)
            print(f"Status: primary={p_healthy}/{len(PRIMARY_BROKERS)} secondary={s_healthy}/{len(SECONDARY_BROKERS)}")
    except KeyboardInterrupt:
        print("Shutting down...")


if __name__ == "__main__":
    main()
