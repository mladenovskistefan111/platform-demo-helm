#!/usr/bin/env bash
# Builds the whole local environment from nothing:
#   kind (no CNI, no kube-proxy) -> Gateway API CRDs -> Cilium (+ Gateway API + Hubble + SPIRE mutual auth)
#   -> TLS secret, namespace and DB credentials (the things that must not live in Git) -> Argo CD -> root Application.
# From there Argo CD deploys everything else from Git (see gitops/README.md). Re-running is safe.
#
# Single sign-on (Dex), the developer portal (Backstage) and Grafana's login need a few things that must not be in Git: kind/sso-secrets.sh
# creates them, kind/sso-bootstrap.sh adds the portal's tokens once Argo CD and Grafana run.
#
# LOCAL_SOURCE=1 kind/up.sh   deploys from this working tree instead of GitHub (nothing is pushed): kind/local-source.sh serves a
#                             staged copy over HTTP and Argo CD reads that. Also loads a locally built Backstage image
#                             (platform-demo-backstage:dev) into the node and publishes the TechDocs into the portal.
set -euo pipefail
cd "$(dirname "$0")/.."

GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.3}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.10.0}"
DOMAIN="${DOMAIN:-platform-demo.test}"
CLUSTER=platform-local

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }
for t in docker kind kubectl helm openssl python3; do need "$t"; done
LOCAL_SOURCE="${LOCAL_SOURCE:-0}"
BACKSTAGE_IMAGE="${BACKSTAGE_IMAGE:-platform-demo-backstage:dev}"

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

step "CoreDNS: pods resolve dex.$DOMAIN to the Dex Service (the issuer URL is the same for browsers and pods)"
if ! kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep -q "dex.$DOMAIN"; then
  kubectl -n kube-system get cm coredns -o json | python3 -c '
import json,sys
cm=json.load(sys.stdin); c=cm["data"]["Corefile"]; dom=sys.argv[1]
c=c.replace("    kubernetes ", "    rewrite name dex."+dom+" dex.sso.svc.cluster.local\n    kubernetes ",1)
cm["data"]["Corefile"]=c; print(json.dumps(cm))' "$DOMAIN" | kubectl apply -f - >/dev/null
  kubectl -n kube-system rollout restart deploy/coredns >/dev/null
  kubectl -n kube-system rollout status deploy/coredns --timeout=2m >/dev/null
fi

step "TLS certificate for *.$DOMAIN (local CA in kind/certs/) -> Secret gateway-system/platform-tls"
DOMAIN="$DOMAIN" bash kind/make-tls.sh

step "Single sign-on prerequisites: namespaces, CA, Dex TLS, client secrets (kind/sso-secrets.sh)"
bash kind/sso-secrets.sh

if [ "$LOCAL_SOURCE" = 1 ]; then
  if docker image inspect "$BACKSTAGE_IMAGE" >/dev/null 2>&1; then
    step "Loading the local Backstage image into the node"
    bash kind/load-image.sh "$BACKSTAGE_IMAGE" mladenovskistefan/platform-demo-backstage:0.1.0
  else
    echo "no local image $BACKSTAGE_IMAGE: Backstage will wait for a released image (see docs: First release)"
  fi
  step "Local source: staging this working tree for Argo CD (nothing is pushed)"
  bash kind/local-source.sh sync
  ROOT="$(bash kind/local-source.sh root)"
else
  ROOT=gitops/bootstrap/root.yaml
fi

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

if [ -n "${DOCKERHUB_USERNAME:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
  step "Docker Hub read credential for Kyverno image verification (Secret kyverno/dockerhub-read, never in Git)"
  kubectl create ns kyverno --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n kyverno create secret docker-registry dockerhub-read --docker-server=https://index.docker.io/v1/ \
    --docker-username="$DOCKERHUB_USERNAME" --docker-password="$DOCKERHUB_TOKEN" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

step "Argo CD $ARGOCD_CHART_VERSION"
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" -n argocd --create-namespace \
  -f gitops/argocd/values.yaml --wait --timeout 8m

step "Root Application (everything else comes from Git)"
kubectl apply -f "$ROOT"

step "Waiting for Argo CD to deploy and heal every Application (up to 15 min)"
for _ in $(seq 1 90); do
  total=$(kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l)
  bad=$(kubectl -n argocd get applications --no-headers 2>/dev/null | awk '$2!="Synced" || $3!="Healthy"' | wc -l)
  [ "$total" -ge 20 ] && [ "$bad" -eq 0 ] && break
  sleep 10
done
kubectl -n argocd get applications

step "Single sign-on: tokens for the portal's read-only accounts in Argo CD and Grafana"
bash kind/sso-bootstrap.sh
if [ "$LOCAL_SOURCE" = 1 ]; then
  step "TechDocs: render every repository's documentation and publish it into the portal"
  bash kind/techdocs-publish.sh
fi

cat <<MSG

Done. Add this line to the Windows hosts file (C:\\Windows\\System32\\drivers\\etc\\hosts) and to WSL /etc/hosts:

  127.0.0.1 shop.$DOMAIN grafana.$DOMAIN argocd.$DOMAIN hubble.$DOMAIN backstage.$DOMAIN dex.$DOMAIN

  https://shop.$DOMAIN      the shop
  https://argocd.$DOMAIN    Argo CD      "Log in via Dex", or local user admin
      admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  https://grafana.$DOMAIN   Grafana (signs in through Dex)
  https://backstage.$DOMAIN the developer portal (signs in through Dex)
  https://dex.$DOMAIN       Dex, the single sign-on provider
      demo user: demo@platform-demo.test   password: cat kind/certs/demo-password
  https://hubble.$DOMAIN    Hubble UI (flows, drops, authentication)

Kyverno:  kubectl get vpol,ivpol,mpol,gpol      policies and their state
          kubectl get polr -A                   audit results per resource
          policies/tests/live/adversarial.sh    live admission tests (see policies/README.md)

Trust kind/certs/ca.crt in your OS/browser to remove the certificate warning.
MSG
