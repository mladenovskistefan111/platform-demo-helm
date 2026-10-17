#!/usr/bin/env bash
# Builds the whole local environment from nothing:
#   kind (no CNI, no kube-proxy) -> Gateway API CRDs -> Cilium (+ Gateway API + Hubble + SPIRE mutual auth)
#   -> TLS secret, namespace and DB credentials (the things that must not live in Git) -> Argo CD -> root Application.
# From there Argo CD deploys everything else from Git (see gitops/README.md). Re-running is safe.
set -euo pipefail
cd "$(dirname "$0")/.."

GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.3}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.10.0}"
DOMAIN="${DOMAIN:-platform-demo.test}"
CLUSTER=platform-local

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }
for t in docker kind kubectl helm openssl; do need "$t"; done

step "kind cluster '$CLUSTER'"
kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --config kind/cluster.yaml

step "Gateway API CRDs $GATEWAY_API_VERSION (must exist before Cilium starts)"
kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null

step "Cilium $CILIUM_VERSION"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" -n kube-system -f kind/cilium-values.yaml --wait --timeout 10m

step "SPIRE: wait for the server, then restart Cilium so every component picks up its identity"
kubectl -n cilium-spire rollout status sts/spire-server --timeout=5m
kubectl -n cilium-spire rollout status ds/spire-agent --timeout=5m
kubectl -n kube-system rollout restart deploy/cilium-operator ds/cilium >/dev/null
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=5m

step "TLS certificate for *.$DOMAIN (local CA in kind/certs/) -> Secret gateway-system/platform-tls"
DOMAIN="$DOMAIN" bash kind/make-tls.sh

step "Namespace platform-demo (Pod Security 'restricted', workload profile) and database credentials (random, never in Git)"
# Created with its labels in one request: the Kyverno policy pd-namespace-pod-security refuses a workload namespace without them.
kubectl apply -f - >/dev/null <<NS
apiVersion: v1
kind: Namespace
metadata:
  name: platform-demo
  labels:
    pod-security.kubernetes.io/enforce: restricted
    platform.demo/profile: workload
NS
if ! kubectl -n platform-demo get secret product-catalog-db-credentials >/dev/null 2>&1; then
  kubectl -n platform-demo create secret generic product-catalog-db-credentials \
    --from-literal=POSTGRES_DB=product_catalog --from-literal=POSTGRES_USER=catalog_user \
    --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 16)" >/dev/null
fi

step "Argo CD $ARGOCD_CHART_VERSION"
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" -n argocd --create-namespace \
  -f gitops/argocd/values.yaml --wait --timeout 8m

step "Root Application (everything else comes from Git)"
kubectl apply -f gitops/bootstrap/root.yaml

step "Waiting for Argo CD to deploy and heal every Application (up to 15 min)"
for _ in $(seq 1 90); do
  total=$(kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l)
  bad=$(kubectl -n argocd get applications --no-headers 2>/dev/null | awk '$2!="Synced" || $3!="Healthy"' | wc -l)
  [ "$total" -ge 16 ] && [ "$bad" -eq 0 ] && break
  sleep 10
done
kubectl -n argocd get applications

cat <<MSG

Done. Add this line to the Windows hosts file (C:\\Windows\\System32\\drivers\\etc\\hosts) and to WSL /etc/hosts:

  127.0.0.1 shop.$DOMAIN grafana.$DOMAIN argocd.$DOMAIN hubble.$DOMAIN

  https://shop.$DOMAIN      the shop
  https://argocd.$DOMAIN    Argo CD      user: admin
      password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  https://grafana.$DOMAIN   Grafana (anonymous admin, local only)
  https://hubble.$DOMAIN    Hubble UI (flows, drops, authentication)

Trust kind/certs/ca.crt in your OS/browser to remove the certificate warning.
MSG
