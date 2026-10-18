#!/usr/bin/env bash
# Second half of the single sign-on setup, once Grafana is running: the portal reads Grafana with the token of a dedicated, read-only
# service account. The token is created here through Grafana's API and stored only in Backstage's Secret. (Argo CD needs nothing: the
# portal reads it with the signed-in person's own Dex token, and Argo CD has no local accounts.)
#
#   kind/sso-bootstrap.sh        (re-run to rotate the token)
set -euo pipefail
need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 1; }; }
need kubectl; need curl; need python3

if ! kubectl -n monitoring get deploy/grafana >/dev/null 2>&1; then
  echo "==> Grafana: not deployed (lean profile): nothing to do"
  exit 0
fi

pf_pids=()
cleanup() { for p in "${pf_pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)"; }

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
kubectl -n backstage patch secret backstage-secrets --type merge -p "{\"stringData\":{\"GRAFANA_TOKEN\":\"$graf_token\"}}" >/dev/null
kubectl -n backstage rollout restart deploy/backstage >/dev/null 2>&1 || true
echo "token stored in backstage/backstage-secrets; Backstage restarts to pick it up"
