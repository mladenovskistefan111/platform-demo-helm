#!/usr/bin/env bash
# Removes the local environment: the kind cluster (and with it Cilium, Argo CD and everything Argo deployed).
# kind/certs/ (local CA) is kept so the next `up.sh` reuses it; delete the directory to start from a new CA.
set -euo pipefail
kind delete cluster --name platform-local
# stop the local source server of `LOCAL_SOURCE=1 kind/up.sh`, if it runs (its staging area under ~/.cache/platform-demo is kept)
bash "$(dirname "$0")/local-source.sh" stop 2>/dev/null || true
