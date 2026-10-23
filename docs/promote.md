# Promote and roll back an image

Nothing is typed into a values file by hand and nothing is rebuilt: an image gets into **dev** when an app repository merges to `main`
(its publish workflow builds once, scans, pushes by digest, signs, and opens the pull request `promote/<app>/dev` that changes
`envs/dev/values/<app>.yaml`). **Stage** and **prod** are moved by a person, from the browser, one app at a time. Every move is a pull
request that passes the same checks as any change; there is no bypass.

## Promote from the browser

Actions -> **Promote** -> Run workflow (branch: `main`), then pick:

| Field | What to choose |
|---|---|
| **app** | a dropdown of the 10 shop services, or `all` (every app whose digest differs) |
| **env** | `stage` (takes what dev runs now) or `prod` (takes what stage runs now) |
| **version** | `X.Y.Z` for stage (required; it becomes the tag and GitHub Release `<app>-vX.Y.Z` of this repository). Empty for prod: the version is taken from stage (if you type one it must equal stage's) |

What happens: the **Plan** job reads the digest of the previous environment on `main` (the registry is never asked for "the newest"),
and shows what will change in the run summary. For `stage` the pull request `promote/<app>/stage` is opened, checked and auto-merged; Argo CD
syncs within ~2 minutes. For `prod` the run first **waits for the reviewer of the GitHub environment `prod`** (Approve job: open the run,
read the plan, press *Review deployments*), then does the same. The promotion policy refuses a digest that is not in the previous
environment, so prod can only run what stage has already run.

## Roll back from the browser

Actions -> **Rollback** -> Run workflow: pick the **app** (dropdown), the **env** (`dev`, `stage` or `prod`) and **to**:

| to | meaning |
|---|---|
| `previous` (default) | the digest the file had before its latest change (run it again to go forward again) |
| `latest` | forward to the newest change: stage and prod take what the previous environment has now |
| `sha256:...` | a digest this app had before in any environment |
| a git SHA | the image of the app as it was at that commit of this repository |

Prod waits for the `prod` reviewer as above. The rollback is a pull request too, so the signature and promotion checks apply to it.

## What CI checks, and the one required check

Every pull request runs the jobs below in parallel (no path filter: a skipped required check counts as passing, so nothing may be skipped).
`gate` waits for all of them and fails when any job failed, was cancelled, or was skipped without a reason it knows (jobs behind a failed
`Helm lint & render` are skipped by GitHub; the gate reports the failed job first instead). **The branch protection of `main` should require
exactly one status check: `gate`.**

| Job (check name) | What it does |
|---|---|
| `Helm lint & render` | `helm lint`, render of every chart and environment (`render-envs.py`), the app dropdowns against the workloads (`check-dispatch-apps.py`) |
| `kubeconform` | schema validation of everything rendered |
| `Trivy config scan` | misconfiguration scan of the rendered charts |
| `Cosign verify images` | every image of ours is pinned by digest and signed by an allowed workflow (below) |
| `Kyverno policy tests` | the policy unit tests, the signer-identity tests, and every rendered app evaluated against the policies |
| `Promotion policy` | which image changes a pull request may make (one environment per PR, stage from dev, prod from stage) |
| `secret-scan / Secret Scan`, `workflows / Workflow lint` | shared workflows of platform-demo-workflows |
| **`gate`** | the only required check |

Until the branch protection of `main` is switched to `gate` (Settings -> Branches, or the API), the eight checks above are listed there
individually; once `gate` has run on a pull request it can be made the only required check and the other eight removed from the list.
The self-tests are `.github/scripts/test-gate.py` (gate scenarios), `test-promotion-policy.sh`, `test-verify-signatures.sh` and
`signer-identities.py test`.

## Who may sign an image (the cosign identity policy)

A keyless signature carries the identity of the workflow that made it. The Helm CI (`Cosign verify images`) and the Kyverno policy
`pd-verify-images` (admission) accept **exactly** the list `verifyImages.signers` in `policies/values.yaml` and nothing else; each entry
says in a comment why it exists and when it can be removed:

| Signer | Why |
|---|---|
| `platform-boutique/platform-demo-workflows` `service-publish.yaml@<40-hex SHA>` | the publish workflow of every app repository: all new images |
| `platform-boutique/platform-demo-workflows` `docker-promote.yaml@<SHA>` | previous generation (workflows v3.0 - v3.3), signer of images already deployed (checkout-service in dev and stage, the portal image) |
| `mladenovskistefan111/platform-demo-workflows` `docker-promote.yaml@<SHA>` | the same workflow before the repository moved to the organisation: the v1.0.0 images in stage and prod |
| `mladenovskistefan111/<service>` `ci-main.yaml@refs/heads/feat/otlp-grpc-telemetry` | the oldest per-repository pipeline; only the umbrella chart's default values still pin such digests |

A workflow of any other repository, another file of the workflows repository, a branch or tag instead of a pinned commit, or a look-alike
name is refused. The list was checked against the real signatures of every digest the charts reference (`cosign verify`, see
`policies/README.md`). To add a signer: edit `policies/values.yaml`, add an allowed fixture (and a refused look-alike) to
`policies/tests/signer-identities/fixtures.yaml`, run `.github/scripts/policy-check.sh`.

The verification retries registry errors (rate limit, 5xx, timeouts: 5 attempts with backoff) but never a verdict ("no signatures found",
"no matching signatures"); the log says which of the two happened. It logs in to Docker Hub with the read-only token
(`DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`) to stay under the anonymous pull limit of shared runner addresses; fork and Dependabot pull
requests get no secrets and verify anonymously.

## Add a service

A new service needs its line in `envs/<env>/workloads.yaml`, its `envs/<env>/values/<app>.yaml` with an `image.digest` and its name in
the `app` options of **both** `.github/workflows/promote.yaml` (after `all`) and `rollback.yaml`, alphabetically. CI fails the pull
request (`check-dispatch-apps.py`) with the exact `options:` line to paste if they have drifted. Hand-made promotion without the workflow
(a pull request changing `image.digest` yourself) still works and goes through the same checks.
