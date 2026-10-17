#!/usr/bin/env bash
# Removes the local environment: the kind cluster (and with it Cilium, Argo CD and everything Argo deployed).
# kind/certs/ (local CA) is kept so the next `up.sh` reuses it; delete the directory to start from a new CA.
set -euo pipefail
kind delete cluster --name platform-local
