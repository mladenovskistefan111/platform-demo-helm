#!/usr/bin/env bash
# Creates a local CA and a wildcard certificate for *.${DOMAIN}, and stores the cert as the Gateway's TLS Secret.
# Import kind/certs/ca.crt into your OS/browser trust store to get rid of the certificate warning.
set -euo pipefail
DOMAIN="${DOMAIN:-platform-demo.test}"
NS="${NS:-gateway-system}"
OUT="$(cd "$(dirname "$0")" && pwd)/certs"
mkdir -p "$OUT"
if [ ! -f "$OUT/ca.crt" ]; then
  openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 825 -keyout "$OUT/ca.key" -out "$OUT/ca.crt" \
    -subj "/CN=platform-demo local CA"
fi
openssl req -newkey rsa:2048 -nodes -keyout "$OUT/tls.key" -out "$OUT/tls.csr" -subj "/CN=*.${DOMAIN}"
openssl x509 -req -sha256 -days 397 -in "$OUT/tls.csr" -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
  -extfile <(printf "subjectAltName=DNS:*.%s,DNS:%s\nextendedKeyUsage=serverAuth" "$DOMAIN" "$DOMAIN") -out "$OUT/tls.crt"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
kubectl -n "$NS" create secret tls platform-tls --cert="$OUT/tls.crt" --key="$OUT/tls.key" --dry-run=client -o yaml | kubectl apply -f -
echo "TLS secret platform-tls applied in $NS; CA: $OUT/ca.crt"
