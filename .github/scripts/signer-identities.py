#!/usr/bin/env python3
"""Who may sign our images: one list, verifyImages.signers in policies/values.yaml.

  signer-identities.py regexp   print the --certificate-identity-regexp for `cosign verify` (the Helm CI gate)
  signer-identities.py test     check the policy chart, the regexp and policies/tests/signer-identities/fixtures.yaml against each other

`test` renders the real pd-verify-images policy (helm template) and fails when
  - the policy does not carry exactly the identities of verifyImages.signers (the template is wired up),
  - a cluster values file overrides the list (the CI gate would then check something other than the cluster enforces),
  - an entry is not anchored (^...$), is not valid regexp syntax RE2 shares, or is broader than the fixtures allow,
  - a fixture identity in `allowed` is refused, or one in `refused` is accepted, by the policy's regexps or by the CI regexp.
Needs PyYAML; `test` also needs helm. Run from the repository root."""
import glob, re, subprocess, sys
import yaml

VALUES = "policies/values.yaml"
FIXTURES = "policies/tests/signer-identities/fixtures.yaml"
CLUSTER_VALUES = "clusters/*/values/policies.yaml"


def signers():
    with open(VALUES) as f:
        v = yaml.safe_load(f)["verifyImages"]
    return v["issuer"], [s["subjectRegExp"] for s in v["signers"]]


def inner(rx):
    """The expression between ^ and $. Go's $ matches only at the end of the text, Python's also before a final newline, so the
    tests match the inner expression with fullmatch (same meaning as Go's anchored match)."""
    if not (rx.startswith("^") and rx.endswith("$")):
        raise ValueError(f"not anchored with ^...$: {rx}")
    return rx[1:-1]


def combined():
    _, rxs = signers()
    return "^(?:" + "|".join(inner(r) for r in rxs) + ")$"


def test():
    issuer, rxs = signers()
    problems = []
    for f in glob.glob(CLUSTER_VALUES):
        with open(f) as fh:
            doc = yaml.safe_load(fh) or {}
        if "signers" in (doc.get("verifyImages") or {}) or "subjectRegExp" in (doc.get("verifyImages") or {}):
            problems.append(f"{f} overrides verifyImages.signers: the CI gate reads policies/values.yaml only")

    out = subprocess.run(["helm", "template", "policies", "policies", "-s", "templates/verify-images.yaml"] +
                         [x for f in glob.glob(CLUSTER_VALUES) for x in ("-f", f)],
                         check=True, capture_output=True, text=True).stdout
    policy = next(d for d in yaml.safe_load_all(out) if d and d["kind"] == "ImageValidatingPolicy")
    ids = policy["spec"]["attestors"][0]["cosign"]["keyless"]["identities"]
    if [i["subjectRegExp"] for i in ids] != rxs:
        problems.append("the rendered policy does not carry exactly verifyImages.signers")
    if any(i["issuer"] != issuer for i in ids):
        problems.append("the rendered policy has an issuer other than verifyImages.issuer")
    policy_rxs = [i["subjectRegExp"] for i in ids]

    with open(FIXTURES) as f:
        fx = yaml.safe_load(f)
    for rx in policy_rxs:
        try:
            inner(rx)
        except ValueError as e:
            problems.append(str(e))
    if problems:
        return problems

    # What the policy decides: any identity (OR). What the gate decides: the combined expression.
    comb = inner(combined())
    for subject in fx["allowed"]:
        if not any(re.fullmatch(inner(r), subject) for r in policy_rxs):
            problems.append(f"policy refuses an identity that must be allowed: {subject}")
        if not re.fullmatch(comb, subject):
            problems.append(f"CI gate regexp refuses an identity that must be allowed: {subject}")
    for subject in fx["refused"]:
        if any(re.fullmatch(inner(r), subject) for r in policy_rxs):
            problems.append(f"policy accepts an identity that must be refused: {subject}")
        if re.fullmatch(comb, subject):
            problems.append(f"CI gate regexp accepts an identity that must be refused: {subject}")
    # Every entry is exercised by at least one allowed fixture (a dead entry is a broader pattern nobody tested).
    for r in policy_rxs:
        if not any(re.fullmatch(inner(r), s) for s in fx["allowed"]):
            problems.append(f"no allowed fixture matches the signer {r}")
    if not problems:
        print(f"signer identities: {len(rxs)} signers, {len(fx['allowed'])} allowed and {len(fx['refused'])} refused fixtures checked")
    return problems


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "regexp":
        print(combined())
    elif cmd == "test":
        probs = test()
        for p in probs:
            print(f"::error::{p}")
        sys.exit(1 if probs else 0)
    else:
        sys.exit(__doc__)
