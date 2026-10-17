#!/usr/bin/env bash
# Puts a locally built image into the kind node's containerd, so the pod starts without pulling it from a registry.
#   kind/load-image.sh <local-image> [<name-in-the-cluster>]
# `kind load docker-image` fails on this machine (content digest not found with Docker's containerd image store); piping
# `docker save` into `ctr images import` on the node works. The charts reference images as <name>:<tag>@<digest>, which the
# kubelet resolves to the name <name>@<digest>: that name is created explicitly (without it the kubelet would try to pull the
# digest from the registry). The digest of a locally built image is its image ID (the digest of its index).
set -euo pipefail
SRC="${1:?usage: load-image.sh <local-image> [<name-in-the-cluster>]}"
DST="${2:-$SRC}"
NODE="${KIND_NODE:-platform-local-control-plane}"
docker tag "$SRC" "$DST"
DIGEST="$(docker image inspect "$DST" --format '{{.Id}}')"
case "$DST" in */*) FULL="docker.io/$DST" ;; *) FULL="docker.io/library/$DST" ;; esac
docker save "$DST" | docker exec -i "$NODE" ctr -n k8s.io images import - >/dev/null
docker exec "$NODE" ctr -n k8s.io images tag --force "$FULL" "${FULL%%:*}@$DIGEST" >/dev/null
echo "loaded $DST as ${FULL%%:*}@$DIGEST into $NODE"
