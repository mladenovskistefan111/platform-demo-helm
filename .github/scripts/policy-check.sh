#!/usr/bin/env bash
# Kyverno policy checks, run in CI and locally:  .github/scripts/policy-check.sh <dir with render-envs.py output>
#   1. unit tests (policies/tests): every policy has pass/fail fixtures
#   2. the manifests Argo CD would deploy are evaluated against the policies, so a chart change that a policy would refuse
#      at admission fails the pull request instead of failing the sync.
# Needs: helm, kyverno (CLI), python3 with PyYAML. Run from the repository root.
set -euo pipefail
rendered="${1:?usage: policy-check.sh <rendered-dir>}"
env_values=envs/dev/values/policies.yaml
out=policies/.rendered
rm -rf "$out"; mkdir -p "$out"

for t in identity images hardening guardrails mutation; do
  helm template policies policies -f "$env_values" -s "templates/$t.yaml" > "$out/$t.yaml"
done

# The Kyverno CLI cannot evaluate a namespaceSelector on a custom label (platform.demo/sandbox) offline: test the sandbox mutation
# without it (tests/sandbox); the selector itself is covered by tests/live/adversarial.sh.
python3 - "$out" <<'PY'
import sys, yaml
out = sys.argv[1]
docs = [d for d in yaml.safe_load_all(open(f"{out}/mutation.yaml")) if d and d["metadata"]["name"] == "pd-sandbox-gvisor"]
for d in docs:
    d["spec"]["matchConstraints"].pop("namespaceSelector", None)
yaml.safe_dump_all(docs, open(f"{out}/mutation-sandbox.yaml", "w"), sort_keys=False)
PY

echo "::group::kyverno test"
kyverno test policies/tests
echo "::endgroup::"

# Policies that read the admission request (user, subresource) cannot be evaluated offline; they have background scanning
# switched off, which is how they are recognised here. They are exercised on the cluster (see policies/README.md).
python3 - "$out" <<'PY'
import glob, sys, yaml
out = sys.argv[1]
keep = []
for f in ("identity", "images", "hardening", "guardrails"):
    for d in yaml.safe_load_all(open(f"{out}/{f}.yaml")):
        if d and d.get("spec", {}).get("evaluation", {}).get("background", {}).get("enabled", True):
            keep.append(d)
yaml.safe_dump_all(keep, open(f"{out}/offline.yaml", "w"), sort_keys=False)
print(f"{len(keep)} policies can be evaluated offline")
PY
python3 .github/scripts/inject-namespaces.py "$rendered" "$out/resources.yaml"

echo "::group::kyverno apply (rendered environments)"
kyverno apply "$out/offline.yaml" --resource "$out/resources.yaml" 2>&1 | tee "$out/apply.log"
echo "::endgroup::"
# `kyverno apply` exits 0 on failures; read its summary line.
if ! grep -qE 'fail: 0, warn: [0-9]+, error: 0' "$out/apply.log"; then
  echo "::error::a rendered manifest violates a Kyverno policy (see the log above)"; exit 1
fi
echo "policy check passed"
