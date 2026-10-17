#!/usr/bin/env python3
"""Turn the output of render-envs.py into what the cluster would see, for `kyverno apply`.

usage: inject-namespaces.py <rendered-dir> <out.yaml>     (run from the repository root)

`helm template -n <ns>` does not write metadata.namespace, Argo CD does it at sync time. This adds it (using the namespace
from envs/<env>/{workloads,addons}.yaml) and appends the Namespace objects with the labels the ApplicationSets give them
(gitops/apps/applicationset-*.yaml), so namespace selectors and the namespace policy can be evaluated offline.
"""
import glob
import os
import sys

import yaml

rendered, out = sys.argv[1], sys.argv[2]
CLUSTER_SCOPED = {"Namespace", "ClusterRole", "ClusterRoleBinding", "CustomResourceDefinition", "CiliumClusterwideNetworkPolicy"}


def labels_for(listing, namespace):
    base = {"kubernetes.io/metadata.name": namespace}
    if listing == "workloads":
        return {**base, "pod-security.kubernetes.io/enforce": "restricted", "platform.demo/profile": "workload"}
    return {**base, "pod-security.kubernetes.io/enforce": "baseline", "pod-security.kubernetes.io/warn": "restricted"}


app_info = {}  # file name -> (namespace, listing)
for path in sorted(glob.glob("envs/*/")):
    env = os.path.basename(path.rstrip("/"))
    for listing in ("workloads", "addons"):
        f = os.path.join(path, f"{listing}.yaml")
        if os.path.exists(f):
            for e in yaml.safe_load(open(f)) or []:
                app_info[f"env-{env}-{e['app']}.yaml"] = (e["namespace"], listing)

docs, namespaces = [], {}
for path in sorted(glob.glob(os.path.join(rendered, "env-*.yaml"))):
    namespace, listing = app_info[os.path.basename(path)]
    namespaces[namespace] = labels_for(listing, namespace)
    for d in yaml.safe_load_all(open(path)):
        if not d:
            continue
        if d.get("kind") not in CLUSTER_SCOPED:
            d.setdefault("metadata", {}).setdefault("namespace", namespace)
        docs.append(d)
for name, labels in sorted(namespaces.items()):
    docs.append({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": name, "labels": labels}})
with open(out, "w") as f:
    yaml.safe_dump_all(docs, f, sort_keys=False)
print(f"{len(docs)} objects in {len(namespaces)} namespaces -> {out}")
