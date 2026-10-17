#!/usr/bin/env python3
"""Render every app of every environment exactly like the ApplicationSets do.

usage: render-envs.py <output-dir>     (run from the repository root, after `helm dependency build`)

For envs/<env>/workloads.yaml the value files are values/common.yaml + values/<app>.yaml; for addons.yaml only
values/<app>.yaml (see gitops/apps/applicationset-*.yaml). Output: <output-dir>/env-<env>-<app>.yaml
Also fails when a listed chart directory does not exist, so a typo in an env file is caught in the pull request.
"""
import glob
import os
import subprocess
import sys

import yaml

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
failures = 0
rendered = 0

for env_dir in sorted(glob.glob("envs/*/")):
    env = os.path.basename(env_dir.rstrip("/"))
    for listing, use_common in (("workloads.yaml", True), ("addons.yaml", False)):
        path = os.path.join(env_dir, listing)
        if not os.path.exists(path):
            continue
        for entry in yaml.safe_load(open(path)) or []:
            app, chart, namespace = entry["app"], entry["chart"], entry["namespace"]
            if not os.path.isfile(f"{chart}/Chart.yaml"):
                print(f"::error::{path}: chart directory '{chart}' for app '{app}' does not exist")
                failures += 1
                continue
            cmd = ["helm", "template", app, chart, "-n", namespace]
            value_files = ([f"envs/{env}/values/common.yaml"] if use_common else []) + [f"envs/{env}/values/{app}.yaml"]
            cmd += [x for vf in value_files if os.path.exists(vf) for x in ("-f", vf)]
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                print(f"::error::helm template failed for {env}/{app}:\n{result.stderr}")
                failures += 1
                continue
            with open(os.path.join(out, f"env-{env}-{app}.yaml"), "w") as f:
                f.write(result.stdout)
            rendered += 1

print(f"rendered {rendered} apps, {failures} failure(s)")
sys.exit(1 if failures else 0)
