#!/usr/bin/env python3
"""Test of the `gate` job of .github/workflows/ci.yaml. The script is taken out of the YAML as written, run with bash and fed what
GitHub gives it (NEEDS = toJSON(needs), EVENT_NAME). Also checks the wiring: gate needs EVERY other job, runs always, no job of the
workflow has a path filter that could make it skip, and the jobs the gate script knows are the jobs it needs.
Needs bash, jq and PyYAML.   usage: .github/scripts/test-gate.py [path/to/ci.yaml]    exit 1 and one report per failed scenario."""
import json, os, re, subprocess, sys, tempfile
import yaml

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "workflows", "ci.yaml")
with open(path) as f:
    wf = yaml.safe_load(f)
jobs = wf["jobs"]
gate = jobs["gate"]
others = [j for j in jobs if j != "gate"]
step = next(s for s in gate["steps"] if s.get("name", "").startswith("Every job passed"))
script = step["run"]
failures, count = [], 0


def wiring(name, ok, why=""):
    global count
    count += 1
    if not ok:
        failures.append(f"wiring: {name}: {why}")


triggers = wf.get("on", wf.get(True))  # PyYAML reads the key `on` as True
wiring("gate needs every other job", sorted(gate["needs"]) == sorted(others), f"needs {sorted(gate['needs'])}, jobs {sorted(others)}")
wiring("gate always runs", "always()" in str(gate.get("if", "")), f"if: {gate.get('if')!r}")
m = re.search(r"^\s*jobs=\(([^)]*)\)", script, re.M)
wiring("the script lists the same jobs", bool(m) and sorted(m.group(1).split()) == sorted(others), f"script {m and m.group(1)}, jobs {others}")
wiring("pull_request has no path filter", not any(k in (triggers.get("pull_request") or {}) for k in ("paths", "paths-ignore")),
       "a skipped workflow leaves a required check pending forever")
wiring("promotion-policy runs on every pull request", "if" in jobs["promotion-policy"] and jobs["promotion-policy"]["if"] == "github.event_name == 'pull_request'", "its `if` changed")
wiring("kyverno-policies starts at t=0", not jobs["kyverno-policies"].get("needs"), f"needs {jobs['kyverno-policies'].get('needs')}")
wiring("gate is not a dependency of anything", all("gate" not in (j.get("needs") or []) for j in jobs.values() if isinstance(j.get("needs"), list)))


def run(needs, event="pull_request"):
    with tempfile.TemporaryDirectory() as tmp:
        summary = os.path.join(tmp, "summary.md")
        open(summary, "w").close()
        env = {"PATH": os.environ["PATH"], "NEEDS": json.dumps(needs), "EVENT_NAME": event, "GITHUB_STEP_SUMMARY": summary}
        p = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script], env=env, capture_output=True, text=True)
        return p.returncode, p.stdout, open(summary).read()


def needs(event="pull_request", **override):
    n = {j: {"result": "success", "outputs": {}} for j in others}
    if event == "workflow_dispatch":
        n["promotion-policy"]["result"] = "skipped"
    for j, r in override.items():
        n[j.replace("_", "-")]["result"] = r
    return n


def check(name, expect_ok, n, event="pull_request", contains=(), absent=(), first=None):
    global count
    count += 1
    rc, out, summ = run(n, event)
    text = out + summ
    problems = []
    if (rc == 0) != expect_ok:
        problems.append(f"exit code {rc}, expected {'0' if expect_ok else 'non-zero'}")
    problems += [f"missing {s!r}" for s in contains if s not in text]
    problems += [f"unexpected {s!r}" for s in absent if s in text]
    if first:  # this job must come first in the report (log and table)
        for where, t in (("log", out), ("summary table", summ.split("| job |", 1)[-1])):
            rows = [l.split()[0] if where == "log" else l.split("|")[1].strip() for l in t.splitlines()
                    if (where == "log" and re.match(r"^[a-z-]+ +(success|failure|cancelled|skipped) ", l)) or (where == "summary table" and re.match(r"^\| [a-z-]+ \|", l))]
            if not rows or rows[0] != first:
                problems.append(f"{first} is not the first row of the {where}: {rows[:3]}")
    if problems:
        failures.append(f"{name}: {'; '.join(problems)}\n{text}")


check("all green (pull request)", True, needs())
check("all green (manual run: promotion policy skipped)", True, needs("workflow_dispatch"), "workflow_dispatch", contains=["| promotion-policy | skipped | skipped |"])
check("manual run but the promotion policy ran", False, needs(), "workflow_dispatch", contains=["promotion-policy is 'success', expected 'skipped'"])
check("pull request but the promotion policy was skipped", False, needs(promotion_policy="skipped"), contains=["promotion-policy is 'skipped', expected 'success'"])
check("one job failed: named first", False, needs(trivy_config="failure"), contains=["trivy-config failure"], absent=["expected 'success'"], first="trivy-config")
check("the LAST job in the list failed: still first in the report", False, needs(workflows="failure"), contains=["workflows failure"], first="workflows")
check("a job was cancelled: named first", False, needs(kyverno_policies="cancelled"), contains=["kyverno-policies cancelled"], first="kyverno-policies")
check("failed and cancelled", False, needs(kubeconform="failure", secret_scan="cancelled"), contains=["kubeconform failure", "secret-scan cancelled"])
check("unexpected skip, nothing failed", False, needs(kubeconform="skipped"), contains=["kubeconform is 'skipped', expected 'success'"])
check("the required job behind the render was skipped but nothing failed", False, needs(verify_signatures="skipped"), contains=["verify-signatures is 'skipped'"])
n = needs(lint_and_render="failure")
for j in ("kubeconform", "trivy-config", "verify-signatures"):
    n[j]["result"] = "skipped"
check("render failed, the three jobs behind it skipped: only the render is the cause", False, n,
      contains=["lint-and-render failure"], absent=["expected 'success'"], first="lint-and-render")
n = needs(promotion_policy="failure")
n["kubeconform"]["result"] = "skipped"
check("a failure and an unrelated skip: only the failure is reported", False, n, contains=["promotion-policy failure"], absent=["kubeconform is 'skipped'"])
n = needs()
del n["kyverno-policies"]
check("a job is missing from needs", False, n, contains=["job kyverno-policies is missing from needs"])
n = needs()
del n["workflows"]
check("the reusable-workflow job is missing from needs", False, n, contains=["job workflows is missing from needs"])
check("a job nobody told the gate about", False, {**needs(), "lint-extra": {"result": "success", "outputs": {}}}, contains=["lint-extra", "(unknown job)", "expected '(unknown job)'"])
check("an unknown result value", False, needs(kubeconform="startup_failure"), contains=["kubeconform is 'startup_failure'"])
check("an event the workflow is not written for", False, needs(), "push", contains=["event 'push'"])
check("step summary has the table", True, needs(), contains=["| job | result | expected |", "| lint-and-render | success | success |", "### Gate (pull_request)"])

if failures:
    print("\n\n".join(failures))
    print(f"\n{len(failures)} of {count} gate checks failed")
    sys.exit(1)
print(f"gate: {count} checks ok")
