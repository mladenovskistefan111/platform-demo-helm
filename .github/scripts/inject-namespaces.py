#!/usr/bin/env python3
"""Turn the output of render-envs.py into what the cluster would see, for `kyverno apply`.

usage: inject-namespaces.py <rendered-dir> <out.yaml>     (run from the repository root)

`helm template -n <ns>` does not write metadata.namespace, Argo CD does it at sync time. This adds it (using the namespace
from envs/<env>/workloads.yaml and clusters/<cluster>/addons.yaml). The Namespace objects, with the labels that decide Pod Security,
the workload profile and the sandbox, come from the rendered cluster-bootstrap chart (clusters/<cluster>/values/cluster-bootstrap.yaml),
the only place that creates namespaces: so namespace selectors and the namespace policy are evaluated offline against the real labels.
An app whose namespace is not declared there fails the check (the ApplicationSets do not create namespaces).

All environments and the platform are one cluster today, so every rendered file is evaluated together, the way the cluster would see
them (three shop namespaces side by side). Rendered files: env-<env>-<app>.yaml (shop), cluster-<cluster>-<app>.yaml (platform).
"""
import glob
import os
import sys

import yaml

rendered, out = sys.argv[1], sys.argv[2]
CLUSTER_SCOPED = {"Namespace", "ClusterRole", "ClusterRoleBinding", "CustomResourceDefinition", "CiliumClusterwideNetworkPolicy", "RuntimeClass"}

app_info = {}  # file name -> (where, namespace)
for path in sorted(glob.glob("envs/*/workloads.yaml")):
    env = path.split("/")[1]
    for e in yaml.safe_load(open(path)) or []:
        app_info[f"env-{env}-{e['app']}.yaml"] = (f"envs/{env}", e["namespace"])
for path in sorted(glob.glob("clusters/*/addons.yaml")):
    cluster = path.split("/")[1]
    for e in yaml.safe_load(open(path)) or []:
        app_info[f"cluster-{cluster}-{e['app']}.yaml"] = (f"clusters/{cluster}", e["namespace"])

declared = {}  # namespace -> Namespace object (one cluster)
docs, errors = [], 0
for path in sorted(glob.glob(os.path.join(rendered, "env-*.yaml")) + glob.glob(os.path.join(rendered, "cluster-*.yaml"))):
    name = os.path.basename(path)
    where, namespace = app_info.get(name, (None, None))
    for d in yaml.safe_load_all(open(path)):
        if not d:
            continue
        if d.get("kind") == "Namespace":
            d["metadata"].setdefault("labels", {})["kubernetes.io/metadata.name"] = d["metadata"]["name"]
            declared[d["metadata"]["name"]] = d
        elif namespace and d.get("kind") not in CLUSTER_SCOPED:
            d.setdefault("metadata", {}).setdefault("namespace", namespace)
        docs.append(d)

for name, (where, namespace) in sorted(app_info.items()):
    if namespace not in declared:
        print(f"::error::{where}: namespace '{namespace}' of {name[:-5]} is not declared in clusters/*/values/cluster-bootstrap.yaml")
        errors += 1
with open(out, "w") as f:
    yaml.safe_dump_all(docs, f, sort_keys=False)
print(f"{len(docs)} objects in {len(declared)} namespaces -> {out}")
sys.exit(1 if errors else 0)
