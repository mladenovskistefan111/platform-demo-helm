#!/usr/bin/env bash
# Renders the TechDocs of every repository in the workspace and copies the sites into the portal's volume.
#   kind/techdocs-publish.sh
# In a real deployment CI does the same on every merge: `techdocs-cli generate` then `techdocs-cli publish` to object storage.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_DIR="${WORKSPACE_DIR:-$(cd "$HERE/../../.." && pwd)}"
BACKSTAGE_REPO="${BACKSTAGE_REPO:-$WORKSPACE_DIR/platform/platform-demo-backstage}"
OUT="${TECHDOCS_OUT:-$HOME/.cache/platform-demo/techdocs}"
"$BACKSTAGE_REPO/tools/techdocs/build-docs.sh" "$WORKSPACE_DIR" "$OUT"
kubectl -n backstage rollout status deploy/backstage --timeout=10m >/dev/null
POD="$(kubectl -n backstage get pod -l app.kubernetes.io/name=backstage -o jsonpath='{.items[0].metadata.name}')"
# the image has no tar on purpose? it does (Debian): stream the folder into /data/docs
kubectl -n backstage exec "$POD" -- sh -c 'mkdir -p /data/docs && rm -rf /data/docs/default' 
tar -C "$OUT" -cf - default | kubectl -n backstage exec -i "$POD" -- tar -C /data/docs -xf -
echo "published $(find "$OUT/default" -maxdepth 2 -mindepth 2 -type d | wc -l) sites to $POD:/data/docs"
