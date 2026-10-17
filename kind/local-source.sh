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
#   BACKSTAGE_IMAGE (default platform-demo-backstage:dev) - its digest is written into the staged values/backstage.yaml.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORKSPACE_DIR="${WORKSPACE_DIR:-$(cd "$REPO/../.." && pwd)}"
PORT="${LOCAL_SOURCE_PORT:-8099}"
STAGE="${LOCAL_SOURCE_DIR:-$HOME/.cache/platform-demo/local-source}"
GITHUB_URL="https://github.com/platform-boutique/platform-demo-helm.git"
BACKSTAGE_IMAGE="${BACKSTAGE_IMAGE:-platform-demo-backstage:dev}"
KIND_NETWORK="${KIND_NETWORK:-kind}"

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
