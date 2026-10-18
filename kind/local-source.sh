#!/usr/bin/env bash
# Serves this working tree to the local cluster without pushing anything to GitHub.
#
#   kind/local-source.sh sync     refresh the staging area and the git repository Argo CD reads, start the server if needed
#   kind/local-source.sh root     print the path of the bootstrap manifest to apply (root.yaml pointing at the local source)
#   kind/local-source.sh stop     stop the server
#   kind/local-source.sh status
#
# What it does:
#   1. git repository: a copy of the working tree of platform-demo-helm (committed or not) in which every reference to
#      https://github.com/platform-boutique/platform-demo-helm.git is rewritten to the local server, committed into a bare
#      repository that Argo CD clones over plain HTTP. The files in Git are never changed.
#   2. catalog: the catalog-info.yaml of every repository in the workspace (and the .proto files they reference) copied under
#      /workspace/..., so Backstage (app-config.kind.yaml) can read them. Only those files are served - no .git, no secrets.
#   3. a small HTTP server (local-source-server.py: files + Git smart HTTP, clone/fetch only) bound to the address of the kind
#      Docker network's gateway, so pods can reach it and nothing else can.
#
# Environment: WORKSPACE_DIR (default: three levels above this script), LOCAL_SOURCE_PORT (8099),
#   PROFILE (full | portal, see above), BACKSTAGE_IMAGE (default platform-demo-backstage:dev) - its digest is written into the staged values/backstage.yaml.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORKSPACE_DIR="${WORKSPACE_DIR:-$(cd "$REPO/../.." && pwd)}"
PORT="${LOCAL_SOURCE_PORT:-8099}"
STAGE="${LOCAL_SOURCE_DIR:-$HOME/.cache/platform-demo/local-source}"
GITHUB_URL="https://github.com/platform-boutique/platform-demo-helm.git"
BACKSTAGE_IMAGE="${BACKSTAGE_IMAGE:-platform-demo-backstage:dev}"
KIND_NETWORK="${KIND_NETWORK:-kind}"
# PROFILE=full (default) | portal (SSO + Argo CD + Backstage only). Remembered in the staging area so a later
# `local-source.sh sync` keeps the profile `up.sh` started with.
PROFILE="${PROFILE:-$(cat "$STAGE/profile" 2>/dev/null || echo full)}"
mkdir -p "$STAGE"; echo "$PROFILE" >"$STAGE/profile"
# PROFILE_WORKLOADS="currency-service,email-service": which workloads the lean profile deploys (default none). Remembered like the profile.
PROFILE_WORKLOADS="${PROFILE_WORKLOADS-$(cat "$STAGE/profile-workloads" 2>/dev/null || true)}"
echo "$PROFILE_WORKLOADS" >"$STAGE/profile-workloads"

bind_ip() {
  docker network inspect "$KIND_NETWORK" --format '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' 2>/dev/null \
    | grep -v ':' | grep -v '^$' | head -1
}
IP="$(bind_ip || true)"
[ -n "${IP:-}" ] || { echo "the Docker network '$KIND_NETWORK' does not exist yet: create the kind cluster first" >&2; exit 1; }
URL="http://$IP:$PORT"

sync_workspace() {
  rm -rf "$STAGE/www/workspace"; mkdir -p "$STAGE/www/workspace"
  local n=0
  while IFS= read -r f; do
    rel="${f#"$WORKSPACE_DIR"/}"; dir="$(dirname "$rel")"
    mkdir -p "$STAGE/www/workspace/$dir"
    cp "$f" "$STAGE/www/workspace/$rel"
    # files an API entity includes with $text (relative to the descriptor)
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      [ -f "$(dirname "$f")/$p" ] || continue
      mkdir -p "$STAGE/www/workspace/$dir/$(dirname "$p")"
      cp "$(dirname "$f")/$p" "$STAGE/www/workspace/$dir/$p"
    done < <(sed -n 's/^[[:space:]]*\$text:[[:space:]]*\.\/\(.*\)$/\1/p' "$f")
    n=$((n+1))
  done < <(find "$WORKSPACE_DIR" -maxdepth 4 -name catalog-info.yaml -not -path '*/node_modules/*' -not -path '*/.git/*')
  # the environment values the Releases view compares with what runs
  mkdir -p "$STAGE/www/workspace/deploy/platform-demo-helm"
  rm -rf "$STAGE/www/workspace/deploy/platform-demo-helm/envs"
  cp -r "$REPO/envs" "$STAGE/www/workspace/deploy/platform-demo-helm/envs"
  echo "staged $n catalog descriptors and the environment values"
}

sync_git() {
  mkdir -p "$STAGE/work" "$STAGE/www/git"
  if [ ! -d "$STAGE/www/git/platform-demo-helm.git" ]; then
    git init -q --bare -b main "$STAGE/www/git/platform-demo-helm.git"
  fi
  if [ ! -d "$STAGE/work/.git" ]; then git -C "$STAGE/work" init -q -b main; fi
  # working tree = tracked + untracked-but-not-ignored files of the repository, current content
  find "$STAGE/work" -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +
  (cd "$REPO" && git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
     | tar --null -T - -cf -) | tar -C "$STAGE/work" -xf -
  # every reference to the GitHub URL points at the local server in the staged copy
  grep -rIl --exclude-dir=.git "$GITHUB_URL" "$STAGE/work" 2>/dev/null | xargs -r sed -i "s#$GITHUB_URL#$URL/git/platform-demo-helm.git#g"
  # PROFILE=portal: staged copy only (the files in Git stay as they are) - no shop, no monitoring stack, no routes into them.
  if [ "$PROFILE" = portal ]; then
    if [ -n "$PROFILE_WORKLOADS" ]; then
      pat="$(echo "$PROFILE_WORKLOADS" | tr ', ' '||' | sed 's/||*/|/g; s/^|//; s/|$//')"
      { grep -E "^- \{ app: +($pat)," "$STAGE/work/envs/dev/workloads.yaml" || true; } >"$STAGE/work/envs/dev/workloads.lean"
      [ -s "$STAGE/work/envs/dev/workloads.lean" ] || { echo "PROFILE_WORKLOADS '$PROFILE_WORKLOADS' matches nothing in envs/dev/workloads.yaml" >&2; exit 1; }
      mv "$STAGE/work/envs/dev/workloads.lean" "$STAGE/work/envs/dev/workloads.yaml"
    else
      echo '[]' >"$STAGE/work/envs/dev/workloads.yaml"
    fi
    # No SPIRE in this profile: workloads must not demand mutual authentication (their CiliumNetworkPolicy says "required" by default).
    printf 'networkPolicy:\n  cilium:\n    authentication: disabled\n' >>"$STAGE/work/envs/dev/values/common.yaml"
    sed -i '/app: monitoring-local/d' "$STAGE/work/envs/dev/addons.yaml"
    # No admission control while the portal is built: Kyverno and its policies are not deployed (up.sh counts the Applications from this copy).
    rm -f "$STAGE/work/gitops/apps/application-kyverno.yaml" "$STAGE/work/gitops/apps/application-policies.yaml"
    printf 'routes:\n  shop: null\n  grafana: null\n' >>"$STAGE/work/envs/dev/values/platform-gateway.yaml"
    # Grafana is not deployed: hide its cards instead of showing 504s (config overlay of the backstage chart, no image rebuild).
    # Arrays are replaced, not merged, by Backstage's config: the base entries of app.extensions are repeated.
    sed -i 's|^config:$|config:\n  overlay: { app: { extensions: [ { "page:catalog": { config: { path: / } } }, { "entity-content:argocd/ArgoCdPage": false }, { "entity-card:grafana/alerts": false }, { "entity-card:grafana/dashboards": false }, { "entity-card:grafana/overview-dashboard": false } ] } }|' \
      "$STAGE/work/envs/dev/values/backstage.yaml"
    echo "profile portal: workloads: ${PROFILE_WORKLOADS:-none}, no Kyverno/policies, no monitoring-local, no shop/grafana routes"
  fi
  # GitHub login is the only way in (kind/sso-secrets.sh takes GITHUB_OAUTH_CLIENT_ID/SECRET). Staged copy only.
  if [ -n "$(kubectl -n sso get secret dex-secrets -o jsonpath='{.data.GITHUB_CLIENT_ID}' 2>/dev/null)" ]; then
    sed -i '/^github:/{n;s/enabled: false/enabled: true/}' "$STAGE/work/envs/dev/values/dex.yaml"
    echo "dex: GitHub login enabled (OAuth App found in sso/dex-secrets)"
  fi
  # the Backstage image built locally (see kind/load-image.sh)
  if digest="$(docker image inspect "$BACKSTAGE_IMAGE" --format '{{.Id}}' 2>/dev/null)" && [ -n "$digest" ]; then
    sed -i -E "s#backstage: \{ repository: mladenovskistefan/platform-demo-backstage, tag: [^,]+, digest: \"[^\"]*\" \}#backstage: { repository: mladenovskistefan/platform-demo-backstage, tag: 0.1.0, digest: \"$digest\" }#" \
      "$STAGE/work/envs/dev/values/backstage.yaml"
    echo "backstage image digest in the staged values: $digest"
  fi
  git -C "$STAGE/work" add -A
  if ! git -C "$STAGE/work" diff --cached --quiet; then
    git -C "$STAGE/work" -c user.name=local-source -c user.email=local-source@localhost commit -q -m "local source $(date -u +%FT%TZ)"
  fi
  git -C "$STAGE/work" push -q --force "$STAGE/www/git/platform-demo-helm.git" main
  git -C "$STAGE/www/git/platform-demo-helm.git" update-server-info
  echo "git: $URL/git/platform-demo-helm.git @ $(git -C "$STAGE/work" rev-parse --short HEAD)"
}

server_running() { [ -f "$STAGE/server.pid" ] && kill -0 "$(cat "$STAGE/server.pid")" 2>/dev/null; }
start_server() {
  if server_running; then return; fi
  mkdir -p "$STAGE/www"
  nohup python3 "$HERE/local-source-server.py" "$IP" "$PORT" "$STAGE/www" >"$STAGE/server.log" 2>&1 &
  echo $! >"$STAGE/server.pid"
  sleep 1
  server_running || { echo "could not start the server on $IP:$PORT, see $STAGE/server.log" >&2; exit 1; }
  echo "serving $STAGE/www on $URL (pid $(cat "$STAGE/server.pid"))"
}

case "${1:-sync}" in
  sync) sync_workspace; sync_git; start_server ;;
  root) echo "$STAGE/work/gitops/bootstrap/root.yaml" ;;
  stop) if server_running; then kill "$(cat "$STAGE/server.pid")"; rm -f "$STAGE/server.pid"; echo stopped; else echo "not running"; fi ;;
  status) server_running && echo "running on $URL" || echo "not running" ;;
  *) echo "usage: $0 sync|root|stop|status" >&2; exit 2 ;;
esac
