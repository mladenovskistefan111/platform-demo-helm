#!/usr/bin/env python3
"""The `app` dropdowns of the Promote and Rollback workflows must list exactly the shop workloads that have an image to move.

An app qualifies when envs/dev/workloads.yaml declares it AND envs/<env>/values/<app>.yaml has `image.digest` in at least one
environment (product-catalog-db and cart-redis pin their image in the chart and have none). Promote offers `all` first, then the apps
in alphabetical order; Rollback offers the apps only. Fails with the exact `options:` line to paste when a list has drifted.
usage: .github/scripts/check-dispatch-apps.py     (from the repository root; needs PyYAML)"""
import glob, os, sys
import yaml

ENVS = ("dev", "stage", "prod")


def has_image_digest(path):
    with open(path) as f:
        doc = yaml.safe_load(f) or {}
    img = doc.get("image")
    return isinstance(img, dict) and bool(img.get("digest"))


def expected_apps():
    with open("envs/dev/workloads.yaml") as f:
        workloads = [w["app"] for w in yaml.safe_load(f) or []]
    apps = set()
    for env in ENVS:
        for path in glob.glob(f"envs/{env}/values/*.yaml"):
            app = os.path.basename(path)[: -len(".yaml")]
            if app in workloads and has_image_digest(path):
                apps.add(app)
    return sorted(apps)


def options_of(workflow):
    with open(f".github/workflows/{workflow}.yaml") as f:
        doc = yaml.safe_load(f)
    trigger = doc.get("on", doc.get(True))  # PyYAML reads the key `on` as True
    app = trigger["workflow_dispatch"]["inputs"]["app"]
    return app.get("type"), app.get("options")


def main():
    apps = expected_apps()
    if not apps:
        sys.exit("::error::no shop workload with an image found: is this the repository root?")
    problems = []
    for workflow, want in (("promote", ["all"] + apps), ("rollback", apps)):
        kind, got = options_of(workflow)
        if kind != "choice":
            problems.append(f"{workflow}.yaml: input `app` must be `type: choice` (it is {kind!r}), so nobody types a chart name")
        elif got != want:
            missing = sorted(set(want) - set(got or []))
            extra = sorted(set(got or []) - set(want))
            why = []
            if missing:
                why.append(f"missing {', '.join(missing)}")
            if extra:
                why.append(f"not an app with an image: {', '.join(extra)}")
            if not why:
                why.append("same apps, wrong order or duplicates")
            problems.append(f"{workflow}.yaml: the `app` options have drifted from the workloads ({'; '.join(why)}). "
                            f"Set it to:  options: [{', '.join(want)}]")
    for p in problems:
        print(f"::error::{p}")
    if problems:
        sys.exit(1)
    print(f"dispatch dropdowns ok: {len(apps)} apps ({', '.join(apps)})")


if __name__ == "__main__":
    main()
