#!/usr/bin/env bash
# Second half of the single sign-on setup, once Argo CD and Grafana are running: the portal reads both with tokens of dedicated,
# read-only accounts. The tokens are created here through their APIs and stored only in Backstage's Secret.
#
#   kind/sso-bootstrap.sh        (re-run to rotate both tokens)
set -euo pipefail
need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }
need kubectl; need curl; need python3

pf_pids=()
cleanup() { for p in "${pf_pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)"; }

echo "==> Argo CD: token for the read-only account 'backstage'"
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m >/dev/null
kubectl -n argocd port-forward svc/argocd-server 18080:80 >/dev/null 2>&1 & pf_pids+=($!)
sleep 3
admin_pw="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
session="$(curl -fsS -X POST localhost:18080/api/v1/session -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$admin_pw\"}" | jget "['token']")"
argo_token="$(curl -fsS -X POST localhost:18080/api/v1/account/backstage/token -H "Authorization: Bearer $session" \
  -H 'Content-Type: application/json' -d '{"name":"portal"}' | jget "['token']")"

echo "==> Grafana: service account 'backstage' (Viewer) and its token"
kubectl -n monitoring rollout status deploy/grafana --timeout=5m >/dev/null
kubectl -n monitoring port-forward svc/grafana 13000:3000 >/dev/null 2>&1 & pf_pids+=($!)
sleep 3
gpw="$(kubectl -n monitoring get secret grafana-oidc -o jsonpath='{.data.GRAFANA_ADMIN_PASSWORD}' | base64 -d)"
G="curl -fsS -u admin:$gpw -H Content-Type:application/json"
sa_id="$($G "localhost:13000/api/serviceaccounts/search?query=backstage" | jget "['serviceAccounts'][0]['id'] if d['serviceAccounts'] else ''")"
if [ -z "$sa_id" ]; then
  sa_id="$($G -X POST localhost:13000/api/serviceaccounts -d '{"name":"backstage","role":"Viewer"}' | jget "['id']")"
fi
graf_token="$($G -X POST "localhost:13000/api/serviceaccounts/$sa_id/tokens" -d "{\"name\":\"portal-$(date +%s)\"}" | jget "['key']")"

kubectl create ns backstage --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n backstage patch secret backstage-secrets --type merge \
  -p "{\"stringData\":{\"ARGOCD_AUTH_TOKEN\":\"$argo_token\",\"GRAFANA_TOKEN\":\"$graf_token\"}}" >/dev/null
kubectl -n backstage rollout restart deploy/backstage >/dev/null 2>&1 || true
echo "tokens stored in backstage/backstage-secrets; Backstage restarts to pick them up"
