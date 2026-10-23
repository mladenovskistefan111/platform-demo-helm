# Promote and roll back an image

Nothing is typed into a values file by hand and nothing is rebuilt. An image travels **dev -> stage -> prod**, always as a pull request that
changes `image.digest` in `envs/<env>/values/<app>.yaml`, always the digest the previous environment runs now, and every pull request passes
the same checks as any change (no bypass). You click twice: once for stage, once for prod.

## The flow

```
developer: pull request in an app repository -> checks -> review -> merge
   |
   v  (automatic) the app repository's publish workflow: build once, scan, sign, open the pull request promote/<app>/dev here, auto-merge
 DEV is deployed (envs/dev changed on main)
   |
   v  (automatic) workflow "Promote to stage" starts by itself: Plan, then it WAITS
   |      YOU: Actions -> the waiting run -> Review deployments -> tick `stage` -> Approve and deploy      (click 1)
   v  one pull request promote/<app>/stage per app, checks, auto-merge
 STAGE is deployed (envs/stage changed on main; the version tag <app>-vX.Y.Z is made)
   |
   v  (automatic) workflow "Promote to prod" starts by itself: Plan, then it WAITS
   |      the `prod` reviewer: Actions -> the waiting run -> Review deployments -> tick `prod` -> Approve and deploy      (click 2)
   v  one pull request promote/<app>/prod, checks, auto-merge
 PROD is deployed (envs/prod changed on main; nothing starts after this)
```

The environments are `dev`, `stage` and `prod` and nothing else.

## Where to click

**Actions** -> the workflow **Promote to stage** (or **Promote to prod**) -> the run at the top (its title is the commit that started it, for
example `promote(dev): shipping-service sha-aa29ba0`, with the label *Waiting*) -> **Review deployments** -> tick the environment ->
**Approve and deploy** (or *Reject*). The run summary has a table of what will happen: app, version, the digest in the environment now and the
digest it becomes. **One click covers every app of the run**; each app then gets its own pull request. The run ends with a **Result** job that
lists the pull requests. GitHub notifies the reviewers of the environment when a run waits (according to their notification settings).

Jobs of a run: `Plan` (read-only, shows the table), `Approve stage deployment` / `Approve prod deployment` (the click), `Promote <app>` (the
pull request of one app), `Result`.

## What starts a run, and what does not

| Change on `main` | Starts |
|---|---|
| a pull request that changes the `image.digest` of an app in `envs/dev` (normally the automatic `promote(dev)` one) | **Promote to stage** |
| a pull request that changes the `image.digest` of an app in `envs/stage` (a promotion to stage) | **Promote to prod** |
| a change in `envs/prod` | nothing: the chain ends here |
| a rollback (a commit titled `rollback(...)`, from the Rollback form), in any environment | nothing: rolling dev back never moves stage, rolling stage back never moves prod |
| only a comment, the tag, the version comment or another line of a values file changed | nothing to promote: the run ends green without a click |

One run handles all apps of one push, **plus the apps still waiting from an earlier change** (see below). A stage promotion also makes the
tag and release `<app>-vX.Y.Z` (`stage-release.yaml`).

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
`to = latest`, or let the next change in the previous environment start its normal run. If a **Promote to stage** run is waiting for the same app while
you roll dev back, approving it fails the recheck and promotes nothing.

## What CI checks, and the one required check

Every pull request runs the jobs below in parallel (no path filter: a skipped required check counts as passing, so nothing may be skipped).
`gate` waits for all of them and fails when any job failed, was cancelled, or was skipped without a reason it knows (jobs behind a failed
`Helm lint & render` are skipped by GitHub; the gate reports the failed job first instead). **The branch protection of `main` should require
exactly one status check: `gate`.**

| Job (check name) | What it does |
|---|---|
| `Helm lint & render` | `helm lint`, render of every chart and environment (`render-envs.py`), the app dropdowns against the workloads (`check-dispatch-apps.py`) and the wiring of the promotion chain (`check-promotion-chain.py`) |
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
