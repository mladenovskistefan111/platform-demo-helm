#!/usr/bin/env bash
# Everything the single sign-on setup needs that must NOT live in Git: namespaces, the CA ConfigMap, the TLS Secret of Dex and
# the random client secrets. Safe to re-run: existing secrets are kept, so tokens and sessions stay valid.
#
#   kind/sso-secrets.sh
#
# Optional environment (when you have them; otherwise the GitHub login stays off and the demo user is used):
#   GITHUB_OAUTH_CLIENT_ID / GITHUB_OAUTH_CLIENT_SECRET   the OAuth App of the organisation (callback https://dex.<domain>/callback)
#   GITHUB_TOKEN                                          a token for Backstage's catalog discovery (production catalog only)
#
# Secrets created (never printed except the demo password, which is also written to kind/certs/demo-password):
#   sso/dex-secrets            BACKSTAGE_CLIENT_SECRET ARGOCD_CLIENT_SECRET GRAFANA_CLIENT_SECRET DEMO_PASSWORD_HASH GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET
#   sso/dex-tls                the wildcard certificate (Dex serves it to pods that reach it in-cluster)
#   argocd/argocd-oidc         clientSecret (label part-of=argocd: Argo CD only dereferences labelled Secrets)
#   monitoring/grafana-oidc    GRAFANA_CLIENT_SECRET GRAFANA_ADMIN_PASSWORD
#   backstage/backstage-secrets POSTGRES_PASSWORD BACKSTAGE_OIDC_CLIENT_SECRET AUTH_SESSION_SECRET ARGOCD_AUTH_TOKEN GRAFANA_TOKEN GITHUB_TOKEN
#   <ns>/platform-demo-ca      ConfigMap with ca.crt in argocd, monitoring and backstage
set -euo pipefail
cd "$(dirname "$0")"
CERTS="$PWD/certs"
# Profile of the running environment (full | portal): from PROFILE, else the one `up.sh` / `local-source.sh` remembered.
PROFILE="${PROFILE:-$(cat "$HOME/.cache/platform-demo/local-source/profile" 2>/dev/null || echo full)}"
rand() { openssl rand -hex 24; }
have() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }
val()  { kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true; }

[ -f "$CERTS/ca.crt" ] && [ -f "$CERTS/tls.crt" ] || { echo "run kind/make-tls.sh first (kind/certs/ is missing)" >&2; exit 1; }

# Namespaces with the labels the Argo CD add-on template would set anyway (created here because Secrets are needed before the apps sync).
for ns in sso backstage; do
  kubectl apply -f - >/dev/null <<NS
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: restricted
NS
done
# The monitoring namespace (Grafana) only exists in the full profile (PROFILE=portal skips it).
mon=(); [ "$PROFILE" = portal ] || mon=(monitoring)
for ns in argocd "${mon[@]}"; do kubectl create ns "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done

for ns in argocd "${mon[@]}" backstage; do
  kubectl -n "$ns" create configmap platform-demo-ca --from-file=ca.crt="$CERTS/ca.crt" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
kubectl -n sso create secret tls dex-tls --cert="$CERTS/tls.crt" --key="$CERTS/tls.key" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if have sso dex-secrets; then
  B="$(val sso dex-secrets BACKSTAGE_CLIENT_SECRET)"; A="$(val sso dex-secrets ARGOCD_CLIENT_SECRET)"; G="$(val sso dex-secrets GRAFANA_CLIENT_SECRET)"
  H="$(val sso dex-secrets DEMO_PASSWORD_HASH)"
else
  B="$(rand)"; A="$(rand)"; G="$(rand)"
  pw="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-14)"
  printf '%s' "$pw" >"$CERTS/demo-password"; chmod 600 "$CERTS/demo-password"
  if python3 -c 'import bcrypt' 2>/dev/null; then
    H="$(python3 -c 'import bcrypt,sys;print(bcrypt.hashpw(sys.argv[1].encode(),bcrypt.gensalt(10)).decode())' "$pw")"
  elif command -v htpasswd >/dev/null; then
    H="$(htpasswd -bnBC 10 "" "$pw" | tr -d ':\n' | sed 's/^\$2y/$2a/')"
  else
    echo "need python3-bcrypt or htpasswd (apache2-utils) to hash the demo user's password" >&2; exit 1
  fi
  echo "demo user: demo@platform-demo.test / $pw   (kept in kind/certs/demo-password)"
fi
kubectl -n sso create secret generic dex-secrets \
  --from-literal=BACKSTAGE_CLIENT_SECRET="$B" --from-literal=ARGOCD_CLIENT_SECRET="$A" --from-literal=GRAFANA_CLIENT_SECRET="$G" \
  --from-literal=DEMO_PASSWORD_HASH="$H" \
  --from-literal=GITHUB_CLIENT_ID="${GITHUB_OAUTH_CLIENT_ID:-$(val sso dex-secrets GITHUB_CLIENT_ID)}" \
  --from-literal=GITHUB_CLIENT_SECRET="${GITHUB_OAUTH_CLIENT_SECRET:-$(val sso dex-secrets GITHUB_CLIENT_SECRET)}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n argocd create secret generic argocd-oidc --from-literal=clientSecret="$A" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n argocd label secret argocd-oidc app.kubernetes.io/part-of=argocd --overwrite >/dev/null

if [ "$PROFILE" != portal ]; then
  if have monitoring grafana-oidc; then GAP="$(val monitoring grafana-oidc GRAFANA_ADMIN_PASSWORD)"; else GAP="$(rand)"; fi
  kubectl -n monitoring create secret generic grafana-oidc --from-literal=GRAFANA_CLIENT_SECRET="$G" --from-literal=GRAFANA_ADMIN_PASSWORD="$GAP" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi

if have backstage backstage-secrets; then
  PG="$(val backstage backstage-secrets POSTGRES_PASSWORD)"; SS="$(val backstage backstage-secrets AUTH_SESSION_SECRET)"
  AT="$(val backstage backstage-secrets ARGOCD_AUTH_TOKEN)"; GT="$(val backstage backstage-secrets GRAFANA_TOKEN)"
  GH="${GITHUB_TOKEN:-$(val backstage backstage-secrets GITHUB_TOKEN)}"
else
  PG="$(rand)"; SS="$(rand)"; AT=""; GT=""; GH="${GITHUB_TOKEN:-}"
fi
# Empty values are left out: Backstage's config rejects an empty string, and every optional key is `optional: true` in the chart.
args=(--from-literal=POSTGRES_PASSWORD="$PG" --from-literal=BACKSTAGE_OIDC_CLIENT_SECRET="$B" --from-literal=AUTH_SESSION_SECRET="$SS")
[ -n "$AT" ] && args+=(--from-literal=ARGOCD_AUTH_TOKEN="$AT")
[ -n "$GT" ] && args+=(--from-literal=GRAFANA_TOKEN="$GT")
[ -n "$GH" ] && args+=(--from-literal=GITHUB_TOKEN="$GH")
kubectl -n backstage create secret generic backstage-secrets "${args[@]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "single sign-on secrets are in place"
