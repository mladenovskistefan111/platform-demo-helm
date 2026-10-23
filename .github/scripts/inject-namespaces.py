#!/usr/bin/env python3
"""Turn the output of render-envs.py into what the cluster would see, for `kyverno apply`.

usage: inject-namespaces.py <rendered-dir> <out.yaml>     (run from the repository root)

`helm template -n <ns>` does not write metadata.namespace, Argo CD does it at sync time. This adds it (using the namespace
from envs/<env>/{workloads,addons}.yaml). The Namespace objects, with the labels that decide Pod Security, the workload profile and
the sandbox, come from the rendered cluster-bootstrap chart (envs/<env>/values/cluster-bootstrap.yaml), the only place that creates
namespaces: so namespace selectors and the namespace policy are evaluated offline against the real labels. An app whose namespace is
not declared there fails the check (the ApplicationSets do not create namespaces).
"""
import glob
import os
import sys

import yaml

rendered, out = sys.argv[1], sys.argv[2]
CLUSTER_SCOPED = {"Namespace", "ClusterRole", "ClusterRoleBinding", "CustomResourceDefinition", "CiliumClusterwideNetworkPolicy", "RuntimeClass"}

envs = [os.path.basename(p.rstrip("/")) for p in glob.glob("envs/*/")]
app_info = {}  # file name -> (env, namespace)
for path in sorted(glob.glob("envs/*/")):
    env = os.path.basename(path.rstrip("/"))
    for listing in ("workloads", "addons"):
        f = os.path.join(path, f"{listing}.yaml")
        if os.path.exists(f):
            for e in yaml.safe_load(open(f)) or []:
                app_info[f"env-{env}-{e['app']}.yaml"] = (env, e["namespace"])

declared = {}  # env -> {namespace: Namespace object}
docs, errors = [], 0
for path in sorted(glob.glob(os.path.join(rendered, "env-*.yaml"))):
    name = os.path.basename(path)
    env, namespace = app_info.get(name, (None, None))
    for d in yaml.safe_load_all(open(path)):
        if not d:
            continue
        if d.get("kind") == "Namespace":
            env_of_file = next(e for e in sorted(envs, key=len, reverse=True) if name.startswith(f"env-{e}-"))
            d["metadata"].setdefault("labels", {})["kubernetes.io/metadata.name"] = d["metadata"]["name"]
            declared.setdefault(env_of_file, {})[d["metadata"]["name"]] = d
        elif namespace and d.get("kind") not in CLUSTER_SCOPED:
            d.setdefault("metadata", {}).setdefault("namespace", namespace)
        docs.append(d)

for name, (env, namespace) in sorted(app_info.items()):
    if namespace not in declared.get(env, {}):
        print(f"::error::envs/{env}: namespace '{namespace}' of {name[len('env-'+env+'-'):-5]} is not declared in envs/{env}/values/cluster-bootstrap.yaml")
        errors += 1
with open(out, "w") as f:
    yaml.safe_dump_all(docs, f, sort_keys=False)
print(f"{len(docs)} objects in {sum(len(v) for v in declared.values())} namespaces -> {out}")
sys.exit(1 if errors else 0)
