# GitOps: how Argo CD deploys this repository

Argo CD (3.5, chart `argo/argo-cd` 10.10.0) watches this repository and reconciles the cluster to it. Nothing is applied by hand except the one-time bootstrap (`../kind/up.sh` does it).

## Moving parts

| File | Purpose |
|---|---|
| `argocd/values.yaml` | Helm values for Argo CD. Used by `helm install` at bootstrap **and** by `apps/application-argocd.yaml`, so Argo CD upgrades itself from Git. |
| `bootstrap/root.yaml` | Applied once: AppProject `platform-admin` + Application `platform-root`, which syncs `apps/`. |
| `apps/appproject-platform-admin.yaml` | Argo CD itself and these definitions. Cluster-admin by design - keep it tiny. |
| `apps/appproject-platform.yaml` | Workloads and add-ons: only this repo as source, only the listed namespaces, only Namespace/ClusterRole/ClusterRoleBinding at cluster scope. |
| `apps/applicationset-workloads.yaml` | One Application **per (environment, workload)** from `envs/*/workloads.yaml`. Namespace labelled Pod Security `restricted`. |
| `apps/applicationset-addons.yaml` | Same for `envs/*/addons.yaml` (Gateway + routes, monitoring). |
| `apps/application-argocd.yaml` | Argo CD managing its own installation (multi-source: chart from argo-helm, values from this repo). |

## Why ApplicationSets (and not hand-written Applications)

The Argo CD docs recommend ApplicationSets for managing many similar Applications and for cluster bootstrapping. Here the **Git files generator** reads a plain YAML list per environment, so:

- *add an app to an environment* = one line in `envs/<env>/workloads.yaml`;
- *add an environment* = a new `envs/<env>/` directory (the generators match `envs/*/`); a second cluster would add a `destination` field to the list and register the cluster in Argo CD;
- *promote* = change `image.digest` in `envs/<env>/values/<app>.yaml` via PR.

Application names are `<env>-<app>` (`dev-checkout-service`). Helm value files, in order: `envs/<env>/values/common.yaml` (workloads only), `envs/<env>/values/<app>.yaml`; missing files are ignored. Sync policy: automated, prune, self-heal, `ServerSideApply`, `CreateNamespace`, retry with backoff.

**Not used (on purpose):** *RollingSync / progressive syncs* are Beta (3.3+) and force autosync off; worth adopting when there is a second environment to roll through. *Sync waves* are not needed: services retry until the database and Redis are up.

## Operating

```bash
kubectl -n argocd get applications,applicationsets
kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite     # force a re-read of Git
argocd app diff <name> --core        # CLI in "core" mode talks to the cluster directly (set the kubectl namespace to argocd)
```

Git is polled every 2 minutes (`timeout.reconciliation: 120s`, `requeueAfterSeconds: 120`); webhooks are not reachable from a laptop. The admin password is in `argocd-initial-admin-secret`; there is no SSO yet (dex and notifications are disabled), and the default policy is read-only for everyone else.

## Secrets

Git holds no secrets. The DB credentials Secret and the Gateway TLS Secret are created by `kind/up.sh`. For AWS: External Secrets or Sealed Secrets, and cert-manager (see `../HANDOFF.md`).

## Branch testing and `targetRevision`

All Git references here say `main`. To test a branch, change them in a throw-away commit on that branch (`targetRevision:` in `bootstrap/root.yaml`, `apps/*.yaml`; `revision:` in the generators), re-apply `bootstrap/root.yaml`, and revert the commit before merging.
