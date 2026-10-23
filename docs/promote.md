# Promote and roll back an image

Nothing is typed into a values file by hand and nothing is rebuilt. An image travels **dev -> stage -> prod**, always as a pull request that
changes `image.digest` in `envs/<env>/values/<app>.yaml`, always the digest the previous environment runs now, and every pull request passes
the same checks as any change (no bypass). You click twice: once for stage, once for prod.

## The flow

The pipeline lives in the **application repository**: after a merge, its **Publish** run builds, scans and signs the image, and then carries
it through the environments, stopping at one approval click per environment. This repository holds the files and the checks (the Promotion
policy, signature check, render, policy tests) that every promotion pull request must pass.

```
developer: pull request in an app repository -> checks -> review -> merge
   |
   v  (automatic) Publish run in the app repository: build once, scan, sign, open the pull request promote/<app>/dev here, auto-merge
 DEV is deployed (envs/dev changed on main)
   |
   v  same run: "Approve stage deployment" WAITS
   |      YOU: app repository -> Actions -> that Publish run -> Review deployments -> tick `stage` -> Approve and deploy      (click 1)
   v  pull request promote/<app>/stage here, checks, auto-merge
 STAGE is deployed (envs/stage changed on main; the release <app>-vX.Y.Z is made)
   |
   v  same run: "Approve prod deployment" WAITS
   |      the `prod` reviewer: Review deployments -> tick `prod` -> Approve and deploy      (click 2)
   v  pull request promote/<app>/prod here, checks, auto-merge
 PROD is deployed (envs/prod changed on main)
```

The environments are `dev`, `stage` and `prod` and nothing else. Nothing in this repository starts a promotion by itself; the two manual
forms below are for the cases the pipeline does not cover.

## Where to click

In the **application repository**: **Actions** -> the **Publish** run of the merge (status *Waiting*) -> **Review deployments** -> tick the
environment -> **Approve and deploy** (or *Reject*). A newer merge replaces an older run that still waits for the same click.

## The version

- **Stage**: computed. It is the next patch after the newest `<app>-vX.Y.Z` tag of this repository (so `1.0.4` after `1.0.3`; the
  highest version wins, not the newest tag). When the stage file already carries a higher version whose tag is not made yet, that one counts
  too. No version yet: `1.0.0`. The table of the run shows it before you click, marked *(computed)*.
- **To choose another version** (a minor or a major bump): Actions -> **Promote** -> Run workflow, `env` = `stage`, the `app`, and type
  `version` = `X.Y.Z`. That run waits at the same `stage` approval.
- **Prod**: never typed. It is the version of stage, unchanged (the `# vX.Y.Z` comment on stage's `image.digest` line).

## Several changes, and old approvals

A newer run replaces a run that is still waiting: if dev changes again before you approved, the old run is **cancelled** by GitHub and the
new one waits instead. Nothing is lost: the new run lists the apps of the old one again (every app whose dev digest differs from stage's and
was changed after stage's last change; an app you rolled back in stage on purpose stays as it is). Approve the newest run.

Only the waiting approval is replaced. Once you approved, the pull requests are being made and nothing cancels them. Right after the click the
plan is computed again and must equal what you approved; if it does not (for example dev was rolled back while the run waited) the approval
job fails with an explanation and **nothing is promoted**.

If a run was rejected or cancelled, or you want everything at once, use the manual form below.

## The manual form (Promote)

Actions -> **Promote** -> Run workflow (branch: `main`). It does the same thing as the automatic runs (same script and same approval), for the
cases the automatic ones do not cover:

| Field | What to choose |
|---|---|
| **app** | a dropdown of the 10 shop services, or `all` (every app whose digest differs) |
| **env** | `stage` (takes what dev runs now) or `prod` (takes what stage runs now) |
| **version** | stage: empty = computed as above, or `X.Y.Z`. Prod: empty (if you type one it must equal stage's) |

Both environments wait for the click of their reviewer: `stage` for env stage, `prod` for env prod. The promotion policy refuses a digest that
is not in the previous environment, so prod can only run what stage has already run. Hand-made promotion (a pull request that changes
`image.digest` yourself) still works and goes through the same checks.

## Settings behind it (GitHub, once)

- Environment **`stage`**: *Required reviewers* = the person who clicks for stage, *Deployment branches* = `main` only. Without a reviewer
  the stage run does not wait and promotes immediately.
- Environment **`prod`**: *Required reviewers* = the production approver, *Deployment branches* = `main` only.
- The org secrets `PROMOTE_APP_ID` and `PROMOTE_APP_PRIVATE_KEY` (the `platform-demo-promote` GitHub App) are used by all three promotion
  workflows. Required status checks of `main` stay as they are: only `gate`. The promotion workflows are not pull-request checks.

## Roll back from the browser

Actions -> **Rollback** -> Run workflow: pick the **app** (dropdown), the **env** (`dev`, `stage` or `prod`) and **to**:

| to | meaning |
|---|---|
| `previous` (default) | the digest the file had before its latest change (run it again to go forward again) |
| `latest` | forward to the newest change: stage and prod take what the previous environment has now |
| `sha256:...` | a digest this app had before in any environment |
| a git SHA | the image of the app as it was at that commit of this repository |

Prod waits for the `prod` reviewer (Review deployments), as above. The rollback is a pull request too, so the signature and promotion checks apply
to it. A rollback commit starts no promotion workflow, so nothing moves forward by itself afterwards; to go forward again run Rollback with
`to = latest`, or let the next merge in the application repository carry its image through the pipeline again.

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
| `Promotion policy` | which image changes a pull request may make (one environment per PR, stage from dev, prod from stage); also runs the self-tests of the promotion planning (`test-promote.sh`) |
| `secret-scan / Secret Scan`, `workflows / Workflow lint` | shared workflows of platform-demo-workflows |
| **`gate`** | the only required check |

Until the branch protection of `main` is switched to `gate` (Settings -> Branches, or the API), the eight checks above are listed there
individually; once `gate` has run on a pull request it can be made the only required check and the other eight removed from the list.
The self-tests are `.github/scripts/test-gate.py` (gate scenarios), `test-promotion-policy.sh`, `test-promote.sh` (what a promotion run decides), `test-verify-signatures.sh` and
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
