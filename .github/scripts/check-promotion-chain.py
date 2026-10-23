#!/usr/bin/env python3
"""The wiring of the automatic promotion chain (dev -> stage -> prod), checked statically so a later edit cannot break it silently.

  promote-stage.yaml  starts on a push to main that touches envs/dev/values, waits at the environment `stage`
  promote-prod.yaml   starts on a push to main that touches envs/stage/values, waits at the environment `prod`
  nothing starts on envs/prod (the chain ends there), and no workflow other than stage-release.yaml reacts to envs/stage.
Also: the approval job is the ONLY job in the concurrency group (a newer run may cancel a waiting approval, never a promotion), the
promotion job has no environment of its own (one click per run, not one per app) and no permissions (nested-permission rule), and
only the environments dev, stage and prod exist anywhere.
usage: .github/scripts/check-promotion-chain.py     (from the repository root; needs PyYAML)"""
import glob, re, sys
import yaml

problems = []


def load(name):
    with open(f".github/workflows/{name}.yaml") as f:
        return yaml.safe_load(f)


def triggers(doc):
    return doc.get("on", doc.get(True))  # PyYAML reads the key `on` as True


def need(ok, msg):
    if not ok:
        problems.append(msg)


for name, source, env in (("promote-stage", "dev", "stage"), ("promote-prod", "stage", "prod")):
    wf = load(name)
    on = triggers(wf)
    need(list(on) == ["push"], f"{name}: must be started by `push` only (it is {list(on)})")
    push = on.get("push") or {}
    need(push.get("branches") == ["main"], f"{name}: push branches must be [main]")
    need(push.get("paths") == [f"envs/{source}/values/*.yaml"], f"{name}: paths must be exactly envs/{source}/values/*.yaml (got {push.get('paths')})")
    need("concurrency" not in wf, f"{name}: no workflow-level concurrency (it would cancel a promotion that is already running)")
    jobs = wf["jobs"]
    need(list(jobs) == ["plan", "approve", "promote", "result"], f"{name}: jobs must be plan, approve, promote, result (got {list(jobs)})")
    plan, approve, promote = jobs["plan"], jobs["approve"], jobs["promote"]
    need(plan["name"] == "Plan" and approve["name"] == f"Approve {env} deployment" and promote["name"] == "Promote ${{ matrix.app }}",
         f"{name}: job names must be `Plan`, `Approve {env} deployment`, `Promote ${{{{ matrix.app }}}}`")
    need(approve.get("environment") == env, f"{name}: the approval job must use environment: {env}")
    conc = approve.get("concurrency") or {}
    need(conc.get("group") == name and conc.get("cancel-in-progress") is True,
         f"{name}: the approval job needs concurrency {{group: {name}, cancel-in-progress: true}}")
    for j in ("plan", "promote", "result"):
        need("concurrency" not in jobs[j], f"{name}: job {j} must not be in a concurrency group")
        need("environment" not in jobs[j], f"{name}: job {j} must not have an environment (one approval per run)")
    need(promote.get("permissions") == {}, f"{name}: the promote job (a reusable-workflow call) must have `permissions: {{}}`")
    need(promote.get("needs") == ["plan", "approve"], f"{name}: promote must need plan and approve")
    need((promote.get("with") or {}).get("env") == env, f"{name}: promote must call gitops-promote with env: {env}")
    need(promote.get("uses", "").startswith("platform-boutique/platform-demo-workflows/.github/workflows/gitops-promote.yaml@"),
         f"{name}: promote must call gitops-promote")

manual = triggers(load("promote"))
need(list(manual) == ["workflow_dispatch"], f"promote: must be manual only (it is {list(manual)})")

# Loop safety: which workflows start on a push to which environment folder.
reacts = {}
for path in sorted(glob.glob(".github/workflows/*.yaml")):
    on = triggers(yaml.safe_load(open(path))) or {}
    for p in (on.get("push") or {}).get("paths") or []:
        m = re.match(r"envs/(dev|stage|prod)/", p)
        if m:
            reacts.setdefault(m.group(1), []).append(path.split("/")[-1])
need("prod" not in reacts, f"nothing may start on envs/prod (the chain ends there): {reacts.get('prod')}")
need(reacts.get("dev") == ["promote-stage.yaml"], f"envs/dev must start promote-stage.yaml only: {reacts.get('dev')}")
need(sorted(reacts.get("stage", [])) == ["promote-prod.yaml", "stage-release.yaml"], f"envs/stage must start promote-prod and stage-release: {reacts.get('stage')}")

# Environments: only dev, stage, prod.
for path in sorted(glob.glob(".github/workflows/*.yaml")):
    text = open(path).read()
    for m in re.finditer(r"^\s*environment:\s*(\S.*)$", text, re.M):
        value = m.group(1).strip()
        need(value in ("stage", "prod", "${{ inputs.env }}"), f"{path}: unexpected environment {value!r}")

for path in glob.glob(".github/**/*", recursive=True) + glob.glob("docs/*.md") + ["README.md", "gitops/README.md"]:
    try:
        text = open(path).read()
    except (IsADirectoryError, UnicodeDecodeError):
        continue
    if path.endswith("check-promotion-chain.py"):
        continue
    need(not re.search(r"\bu" + "at\\b", text, re.I), f"{path}: stage is the only name for the environment before prod; do not use another")

for p in problems:
    print(f"::error::{p}")
if problems:
    sys.exit(1)
print("promotion chain ok: dev -> promote-stage (stage) -> promote-prod (prod); nothing starts on envs/prod")
