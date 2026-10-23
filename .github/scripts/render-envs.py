#!/usr/bin/env python3
"""Render everything Argo CD deploys exactly like Argo CD does, and check that the wiring between the lists is complete.

usage: render-envs.py <output-dir>     (run from the repository root, after `helm dependency build`)

Two kinds of things are rendered (see gitops/layers/*/applicationset-*.yaml):

  the shop       envs/<env>/workloads.yaml  ->  value files envs/common.yaml + envs/<env>/common.yaml + envs/<env>/values/<app>.yaml
                 output: <output-dir>/env-<env>-<app>.yaml          (Argo CD Application <env>-<app>)
  the platform   clusters/<cluster>/addons.yaml  ->  value file clusters/<cluster>/values/<app>.yaml
                 plus the single-chart Applications of the layers that are not list entries (cluster-bootstrap,
                 platform-network-policies)
                 output: <output-dir>/cluster-<cluster>-<app>.yaml  (Argo CD Application <app>)

It also fails (with ::error:: lines) when
  - an environment has no envs/<env>/common.yaml (its sizing), or a listed chart directory does not exist, or an environment's app name differs from its chart directory name
    (the promotion workflows rely on  <app> == chart directory == envs/<env>/values/<app>.yaml);
  - a service image is not set as image.tag + image.digest (sha256:<64 hex>) in envs/<env>/values/<app>.yaml;
  - two environments share a namespace, or two Argo CD Applications would get the same name;
  - a shop namespace is missing from cluster-bootstrap, policies (scopes.workload), external-secrets-config (allowedNamespaces,
    shop.environments), the AppProjects (workloads, platform, secrets) or the gateway routes, or carries different labels than
    the other shop namespaces. A namespace missing from one of those lists would silently get no policy / no secret / no route.
"""
import glob
import os
import re
import subprocess
import sys

import yaml

OWN_IMAGE_PREFIX = "mladenovskistefan/"
UNSIGNED_OWN_IMAGES = {"product-catalog-db"}  # hand-built, no promotion of its own (see .github/workflows/ci.yaml)

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
failures = 0
rendered = 0


def error(msg):
    global failures
    print(f"::error::{msg}")
    failures += 1


def load(path):
    with open(path) as f:
        return yaml.safe_load(f)


def deep_merge(base, over):
    """Helm's rule: maps merge, everything else (lists included) is replaced."""
    if isinstance(base, dict) and isinstance(over, dict):
        merged = dict(base)
        for k, v in over.items():
            merged[k] = deep_merge(base[k], v) if k in base else v
        return merged
    return over


def chart_values(chart, cluster="main"):
    """Chart defaults overlaid with the cluster's value file for an add-on / cluster chart."""
    values = load(f"{chart}/values.yaml") or {}
    vf = f"clusters/{cluster}/values/{chart}.yaml"
    if os.path.exists(vf):
        values = deep_merge(values, load(vf) or {})
    return values


def helm_template(app, chart, namespace, value_files, target, label):
    global rendered
    cmd = ["helm", "template", app, chart, "-n", namespace]
    for vf in value_files:
        if os.path.exists(vf):
            cmd += ["-f", vf]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        error(f"helm template failed for {label}:\n{result.stderr}")
        return
    with open(os.path.join(out, target), "w") as f:
        f.write(result.stdout)
    rendered += 1


# ─── the shop: envs/<env>/workloads.yaml ─────────────────────────────────────────────────────────────────────────────
env_namespaces = {}  # env -> {namespace: [apps]}
shop_names = set()
for env_dir in sorted(glob.glob("envs/*/")):
    env = os.path.basename(env_dir.rstrip("/"))
    path = os.path.join(env_dir, "workloads.yaml")
    if not os.path.exists(path):
        continue
    if not os.path.exists(f"envs/{env}/common.yaml"):
        error(f"envs/{env}/common.yaml is missing: without it the environment would silently get the charts' HA defaults")
    for entry in load(path) or []:
        app, chart, namespace = entry["app"], entry["chart"], entry["namespace"]
        env_namespaces.setdefault(env, {}).setdefault(namespace, []).append(app)
        shop_names.add(f"{env}-{app}")
        if app != chart:
            error(f"{path}: app '{app}' must equal its chart directory '{chart}' (envs/{env}/values/{app}.yaml is found by that name)")
        if not os.path.isfile(f"{chart}/Chart.yaml"):
            error(f"{path}: chart directory '{chart}' for app '{app}' does not exist")
            continue
        value_file = f"envs/{env}/values/{app}.yaml"
        helm_template(app, chart, namespace, ["envs/common.yaml", f"envs/{env}/common.yaml", value_file], f"env-{env}-{app}.yaml", f"{env}/{app}")

        # Contract with the promotion workflows: our own service images are set as image.tag + image.digest in the app's env file.
        defaults = (load(f"{chart}/values.yaml") or {}).get("image", {})
        repo = defaults.get("repository", "")
        if repo.startswith(OWN_IMAGE_PREFIX) and app not in UNSIGNED_OWN_IMAGES:
            image = ((load(value_file) if os.path.exists(value_file) else None) or {}).get("image") or {}
            if not image.get("tag"):
                error(f"{value_file}: image.tag is not set")
            if not re.fullmatch(r"sha256:[0-9a-f]{64}", str(image.get("digest", ""))):
                error(f"{value_file}: image.digest must be sha256:<64 hex digits>")

# Environments must not share a namespace: that would break the isolation between them.
seen = {}
for env, namespaces in env_namespaces.items():
    for ns in namespaces:
        if ns in seen and seen[ns] != env:
            error(f"namespace '{ns}' is used by environments '{seen[ns]}' and '{env}'")
        seen.setdefault(ns, env)

# ─── the platform: clusters/<cluster>/addons.yaml (+ the single-chart layer Applications) ────────────────────────────
platform_names = set()
STATIC = (("cluster-bootstrap", "cluster-bootstrap", "kube-system"),
          ("platform-network-policies", "platform-network-policies", "argocd"))
for cluster_dir in sorted(glob.glob("clusters/*/")):
    cluster = os.path.basename(cluster_dir.rstrip("/"))
    path = os.path.join(cluster_dir, "addons.yaml")
    entries = [(e["app"], e["chart"], e["namespace"]) for e in (load(path) or [])] if os.path.exists(path) else []
    for app, chart, namespace in entries:
        platform_names.add(app)
        if not os.path.isfile(f"{chart}/Chart.yaml"):
            error(f"{path}: chart directory '{chart}' for app '{app}' does not exist")
            continue
        helm_template(app, chart, namespace, [f"clusters/{cluster}/values/{app}.yaml"], f"cluster-{cluster}-{app}.yaml", f"{cluster}/{app}")
    if os.path.exists(f"clusters/{cluster}/values/cluster-bootstrap.yaml"):
        for app, chart, namespace in STATIC:  # their Application names come from gitops/layers (checked below)
            helm_template(app, chart, namespace, [f"clusters/{cluster}/values/{app}.yaml"], f"cluster-{cluster}-{app}.yaml", f"{cluster}/{app}")

# ─── Application names are unique ────────────────────────────────────────────────────────────────────────────────────
layer_names = []
for f in sorted(glob.glob("gitops/layers/*/*.yaml") + glob.glob("gitops/apps/layer-*.yaml")):
    for d in yaml.safe_load_all(open(f)):
        if d and d.get("kind") == "Application":
            layer_names.append(d["metadata"]["name"])
all_names = layer_names + sorted(platform_names) + sorted(shop_names)
for name in sorted({n for n in all_names if all_names.count(n) > 1}):
    error(f"the Argo CD Application name '{name}' would exist twice")

# ─── wiring: every shop namespace is known to every list that must know it ───────────────────────────────────────────
shop_ns = sorted({ns for namespaces in env_namespaces.values() for ns in namespaces})
for cluster_dir in sorted(glob.glob("clusters/*/")):
    cluster = os.path.basename(cluster_dir.rstrip("/"))
    boot = f"clusters/{cluster}/values/cluster-bootstrap.yaml"
    if not os.path.exists(boot):
        continue
    declared = {n["name"]: n for n in (load(boot) or {}).get("namespaces", [])}
    for ns in shop_ns:
        if ns not in declared:
            error(f"namespace '{ns}' is not declared in {boot}")
    labels = {tuple(sorted((k, str(v)) for k, v in declared[ns].items() if k != "name")) for ns in shop_ns if ns in declared}
    if len(labels) > 1:
        error(f"the shop namespaces do not carry the same labels in {boot}: {sorted(labels)}")
    for ns in shop_ns:
        n = declared.get(ns, {})
        if n and (n.get("podSecurity") != "restricted" or n.get("profile") != "workload"):
            error(f"{boot}: shop namespace '{ns}' must be podSecurity restricted and profile workload")

    policies = chart_values("policies", cluster)
    for ns in shop_ns:
        if ns not in policies.get("scopes", {}).get("workload", []):
            error(f"namespace '{ns}' is missing from scopes.workload of the policies (policies/values.yaml): it would get no policy")

    esc = chart_values("external-secrets-config", cluster)
    for ns in shop_ns:
        if ns not in esc.get("allowedNamespaces", []):
            error(f"namespace '{ns}' is missing from allowedNamespaces of external-secrets-config (the ClusterSecretStores would refuse it)")
    if esc.get("shop", {}).get("enabled"):
        covered = [e["namespace"] for e in esc["shop"].get("environments", [])]
        paths = [e["passwordPath"] for e in esc["shop"].get("environments", [])]
        for ns in shop_ns:
            if ns not in covered:
                error(f"namespace '{ns}' has no entry in shop.environments of external-secrets-config (no database credentials)")
        if len(set(paths)) != len(paths):
            error("two shop environments read the same Parameter Store entry (shop.environments[].passwordPath): credentials must be per environment")

    gateway = chart_values("platform-gateway", cluster)
    routes = {k: r for k, r in gateway.get("routes", {}).items() if r.get("enabled", True)}
    hosts = [r["host"] for r in routes.values()]
    for h in sorted({h for h in hosts if hosts.count(h) > 1}):
        error(f"two gateway routes claim the host '{h}' (platform-gateway)")
    for env, namespaces in env_namespaces.items():
        for ns, apps in namespaces.items():
            if "frontend" in apps and not any(r["namespace"] == ns and r["service"] == "frontend" for r in routes.values()):
                error(f"no gateway route (platform-gateway routes) for the frontend of '{env}' in namespace '{ns}'")

# AppProject destinations (cluster `in-cluster` unless an entry names another one, which the projects must then list explicitly).
for project, needs in (("workloads", "every shop namespace"), ("platform", "the namespaces of the shop routes"), ("secrets", "the shop credentials")):
    spec = load(f"gitops/apps/appproject-{project}.yaml")["spec"]
    listed = {d["namespace"] for d in spec.get("destinations", []) if d.get("name") in ("in-cluster", None)}
    for ns in shop_ns:
        if ns not in listed:
            error(f"gitops/apps/appproject-{project}.yaml: destination namespace '{ns}' is missing ({needs})")

print(f"rendered {rendered} apps, {failures} failure(s)")
sys.exit(1 if failures else 0)
