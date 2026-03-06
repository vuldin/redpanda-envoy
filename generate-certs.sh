#!/bin/bash
#
# Generate TLS certificates for the Envoy TLS passthrough demo.
#
# Creates:
#   - A self-signed CA
#   - Per-broker certificates with SANs including 'envoy' (the hostname
#     clients connect to through the proxy) so that TLS verification
#     succeeds end-to-end even though Envoy is in the middle.
#
# All certs are written to ./certs/

set -euo pipefail

CERTS_DIR="$(cd "$(dirname "$0")" && pwd)/certs"
CA_SUBJECT="/CN=Redpanda Demo CA"
DAYS=365

BROKERS=(
    primary-broker-0
    primary-broker-1
    primary-broker-2
    secondary-broker-0
    secondary-broker-1
    secondary-broker-2
)

# Skip if certs already exist
if [ -d "$CERTS_DIR" ] && [ -f "$CERTS_DIR/ca.crt" ]; then
    echo "Certificates already exist in $CERTS_DIR — skipping generation."
    echo "To regenerate, remove the certs/ directory and re-run."
    exit 0
fi

echo "🔐 Generating TLS certificates in $CERTS_DIR ..."
rm -rf "$CERTS_DIR"
mkdir -p "$CERTS_DIR"

# ── CA ────────────────────────────────────────────────────────────────
echo "  Creating CA key and certificate..."
openssl genrsa -out "$CERTS_DIR/ca.key" 2048 2>/dev/null
openssl req -new -x509 -key "$CERTS_DIR/ca.key" \
    -out "$CERTS_DIR/ca.crt" \
    -days "$DAYS" \
    -subj "$CA_SUBJECT" 2>/dev/null

# ── Per-broker certs ──────────────────────────────────────────────────
for broker in "${BROKERS[@]}"; do
    echo "  Creating certificate for $broker ..."

    # SAN list: the broker's own hostname + envoy (what clients connect to) + localhost
    cat > "$CERTS_DIR/${broker}.ext" <<EOF
[req]
distinguished_name = req_dn
req_extensions     = v3_req
prompt             = no

[req_dn]
CN = ${broker}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${broker}
DNS.2 = envoy
DNS.3 = localhost
EOF

    # Key
    openssl genrsa -out "$CERTS_DIR/${broker}.key" 2048 2>/dev/null

    # CSR
    openssl req -new \
        -key "$CERTS_DIR/${broker}.key" \
        -out "$CERTS_DIR/${broker}.csr" \
        -config "$CERTS_DIR/${broker}.ext" 2>/dev/null

    # Sign with CA
    openssl x509 -req \
        -in "$CERTS_DIR/${broker}.csr" \
        -CA "$CERTS_DIR/ca.crt" \
        -CAkey "$CERTS_DIR/ca.key" \
        -CAcreateserial \
        -out "$CERTS_DIR/${broker}.crt" \
        -days "$DAYS" \
        -extensions v3_req \
        -extfile "$CERTS_DIR/${broker}.ext" 2>/dev/null

    # Clean up intermediary files
    rm -f "$CERTS_DIR/${broker}.csr" "$CERTS_DIR/${broker}.ext"
done

# Clean up serial file
rm -f "$CERTS_DIR/ca.srl"

# Make all files readable by the Redpanda container (runs as UID 101)
chmod 644 "$CERTS_DIR"/*.crt "$CERTS_DIR"/*.key

echo ""
echo "✅ Certificates generated:"
ls -1 "$CERTS_DIR"
echo ""
echo "CA certificate:  $CERTS_DIR/ca.crt"
echo "Broker certs:    $CERTS_DIR/<broker-name>.crt / .key"
echo ""
echo "Each broker cert has SANs: <broker-hostname>, envoy, localhost"
