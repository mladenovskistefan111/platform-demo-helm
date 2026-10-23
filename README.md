# platform-demo-helm

Everything that is deployed: the Helm charts for the platform-demo application (10 services, PostgreSQL, Redis), the Gateway API entry point, and the **GitOps configuration** that makes Argo CD deploy them. This repository is the single source of truth for what runs in each environment; the service repositories only build and publish images.

Context for everything below lives in the [docs repo](https://github.com/platform-boutique/platform-demo-docs): the master [`README.md`](https://github.com/platform-boutique/platform-demo-docs/blob/main/README.md) (architecture, wiring, observability contract, CI/CD model, gotchas) and the session handoff [`HANDOFF.md`](https://github.com/platform-boutique/platform-demo-docs/blob/main/HANDOFF.md).

> `product-catalog-db` is a hand-built, unsigned PostgreSQL image that stays a **StatefulSet in the cluster** for now (the shop is meant to move to another cluster later). It has an allow-list entry in `.github/workflows/ci.yaml` and a Kyverno exception (`verifyImages.unsigned`). The only RDS database is Backstage's.

## How it fits together

```
service repos  --release tag-->  Docker Hub (signed image, digest)
                                        |  PR: bump image.tag + image.digest in envs/<env>/values/<app>.yaml
                                        v
platform-demo-helm  (this repo, main)  <--- Argo CD polls --- app-of-apps layers (gitops/apps, gitops/layers)
   charts + envs/ + clusters/ + gitops/                          |
                                                                  v
                       shop: one Application per (env, app) = dev-/stage-/prod-<app>  -> namespaces dev-/stage-/platform-demo
                       platform: one Application per add-on of clusters/main/ -> platform namespaces (argocd, kyverno, sso ...)
```

- **Charts** (`<service>/`, `platform-common/`, `platform-gateway/`, `dex/`, `backstage/`, `cluster-bootstrap/`, `platform-network-policies/`, `external-secrets-config/`) describe *how* something is deployed.
- **`envs/<env>/`** (`dev`, `stage`, `prod`) is the shop only, three environments on one cluster: `workloads.yaml` (the app list) and `values/<app>.yaml` (image tag + digest, per-env settings); `envs/common.yaml` holds only what is identical in every environment (mutual authentication); `envs/<env>/common.yaml` is the sizing of that environment (replicas, HPA/PDB). **Promotion = a pull request that changes a digest.**
- **`clusters/<cluster>/`** (`main` today) is everything that is not the shop: `addons.yaml` (Gateway, Dex, Backstage) and `values/<name>.yaml` for those and for the cluster-wide charts (cluster-bootstrap incl. the namespace list, policies, external-secrets-config). A later management/app cluster split adds a directory here.
- **`gitops/`** is Argo CD's own configuration: install values, the root Application, projects, the two ApplicationSets and the Kyverno Applications. See [`gitops/README.md`](gitops/README.md).
- **`policies/`** are the Kyverno admission policies (identity, images and signatures, pod hardening, exposure, break-glass, namespace baseline). See [`policies/README.md`](policies/README.md).

## Layout

```
platform-common/          library chart (templates only): Deployment, StatefulSet, Service, HPA, PDB, NetworkPolicy and
                          CiliumNetworkPolicy (networkPolicy.type), probes, security context helpers
<service>/                10 Deployments + product-catalog-db / cart-redis StatefulSets; thin charts over platform-common
platform-gateway/         Gateway (Cilium GatewayClass, plain HTTP on 8080 behind the ALB) and HTTPRoutes: shop (prod) + dev.shop + stage.shop, argocd, hubble, backstage, dex
cluster-bootstrap/        namespaces with their labels (Pod Security, Kyverno profile, gVisor), RuntimeClass gvisor, the one-off SPIRE/Cilium restart Job
platform-network-policies/ default-deny and allow rules (CiliumNetworkPolicy) for argocd, sso, backstage, gateway-system
external-secrets-config/  ClusterSecretStores and ExternalSecrets (AWS SSM Parameter Store / Secrets Manager -> Kubernetes Secrets)
dex/, backstage/          SSO provider (Dex) and the developer portal (Backstage on RDS); deployed as add-ons from clusters/main/addons.yaml
monitoring/               vendored upstream charts (unchanged; not deployed yet)
platform-demo/            umbrella chart: `helm install` of the whole app without Argo CD (values-dev/prod.yaml)
envs/common.yaml          only what is identical in every environment (mutual authentication)
envs/{dev,stage,prod}/    the shop per environment: workloads.yaml (app list + namespace), common.yaml (sizing), values/<app>.yaml (image tag + digest, differences)
clusters/main/            the platform of the cluster: addons.yaml, values/{cluster-bootstrap (the namespace list),policies,external-secrets-config,platform-gateway,dex,backstage}.yaml
gitops/                   app-of-apps: bootstrap/root.yaml (Terraform mirrors it), apps/ (AppProjects + one Application per layer), layers/{bootstrap,security,platform,workloads}/ (sync-wave ordered Applications and ApplicationSets), argocd/values.yaml, kyverno/values.yaml
policies/                 Kyverno policies (CEL policy types) + tests; README explains each policy, rollout, exceptions, break-glass
.github/                  ci.yaml (PR gate), scripts/ (render-envs.py, policy-check.sh, inject-namespaces.py), CODEOWNERS, dependabot.yml
```

Every service chart is ~6 tiny template files that call into `platform-common` plus a fully commented `values.yaml`, so behaviour is identical everywhere and a fix in the library reaches all charts.

## Deploy

The target is an **EKS** cluster whose infrastructure (VPC, cluster, Cilium, nodes, ALB, DNS) is created by the
[infra-terraform](https://github.com/platform-boutique/infra-terraform) repository. This repository is everything that runs *on* the cluster, and Argo CD applies it.

1. Terraform creates the cluster with Cilium (CNI, kube-proxy replacement, Gateway API in host-network mode) and the ALB in front of it.
2. Terraform also installs Argo CD (chart `argo/argo-cd`, bootstrap values only) and creates the objects of `gitops/bootstrap/root.yaml` (the AppProject `platform-admin` and the Application `platform-root`); nothing is applied by hand.
   From there Argo CD creates the projects, the ApplicationSets, itself (from `gitops/argocd/values.yaml`), Kyverno and the policies, and one Application per entry of `clusters/main/addons.yaml` and of `envs/<env>/workloads.yaml`. See [`gitops/README.md`](gitops/README.md).
3. Secrets are not in Git. They live in AWS Systems Manager Parameter Store (`/platform-demo/...`) and reach the cluster through External Secrets
   (see `secrets.md` in infra-terraform).
4. The hostnames are `argocd`, `backstage`, `dex`, `hubble` and `shop` under `platform-demo.click`, plus `dev.shop` and `stage.shop` for the other two shop environments (`grafana` is a disabled route: no Grafana is deployed); people sign in with GitHub through Dex. Hosts, DNS records and certificate names are Terraform's; see [Environments](docs/environments.md).

### Without Argo CD

Any cluster with a CNI that enforces NetworkPolicy can run the application from the umbrella chart:

```bash
kubectl create namespace platform-demo
kubectl label ns platform-demo pod-security.kubernetes.io/enforce=restricted   # the charts comply
cd platform-demo && helm dependency update
helm upgrade --install platform-demo . -n platform-demo -f values-dev.yaml          # small profile, demo DB password
helm upgrade --install platform-demo . -n platform-demo \
  --set product-catalog-db.auth.existingSecret=product-catalog-db-credentials        # HA defaults, needs metrics-server
```

Prerequisites either way: the service images on Docker Hub (pinned by digest, built, scanned and signed by the shared publish workflow), and HTTPS in front of the frontend (its cookies are `Secure`).
The services export telemetry to `alloy.monitoring.svc.cluster.local` (or `--set global.monitoring.*`); no collector is deployed on the EKS cluster yet, so the exports fail and only add log noise.

## Promote an image

Nothing is typed and nothing is rebuilt. The pipeline runs in the **application repository** (its Publish run); this repository holds the
state and the checks every change has to pass:

```
merge in an app repository -> its Publish run: build once, scan, sign -> pull request promote/<app>/dev here, auto-merged  = DEV deployed
   -> same run, in the app repository: "Approve stage deployment" waits   (Review deployments -> `stage` -> Approve)   (click 1)
   -> pull request promote/<app>/stage here, auto-merged                   = STAGE deployed (version <app>-vX.Y.Z: the next patch)
   -> same run: "Approve prod deployment" waits                            (Review deployments -> `prod`  -> Approve)   (click 2)
   -> pull request promote/<app>/prod here, auto-merged                    = PROD deployed
```

A newer merge replaces a run that is still waiting. **Actions -> Promote** here is the manual form (several apps at once, or a version you choose) (app
dropdown or `all`, env, and an optional `version` for a minor/major bump); it waits at the same approvals. **Actions -> Rollback** goes the other
way (app, env, `previous` / `latest` / a digest / a git SHA). Details, the required check (`gate`) and the signer policy: [docs/promote.md](docs/promote.md).

## What each chart provides

| | |
|---|---|
| Workload | `Deployment` (or `StatefulSet` for the two stores), RollingUpdate with `maxUnavailable: 0`, `minReadySeconds`, `revisionHistoryLimit` |
| Scaling | `HorizontalPodAutoscaler` v2 (CPU 70 %, scale-down stabilisation 300 s), replicas owned by the HPA when enabled |
| Availability | `PodDisruptionBudget` (`maxUnavailable: 1`, `AlwaysAllow` for unhealthy pods), soft topology spread, `preStop` sleep, per-service termination grace |
| Probes | startup / readiness / liveness (native `grpc` probes for gRPC services, `httpGet` for the frontend, `exec` for Postgres/Redis) |
| Resources | requests + limits for every container (sized from measured usage) |
| Security | restricted Pod Security profile: non-root numeric UID/GID, read-only root FS with explicit `/tmp`, no privilege escalation, all capabilities dropped, `RuntimeDefault` seccomp, no ServiceAccount token, no service links |
| Network | default-deny with allow-lists: `NetworkPolicy` (any CNI) or, with `networkPolicy.type: cilium`, a `CiliumNetworkPolicy` that also requires **SPIFFE/SPIRE mutual authentication** between workloads (ingress only from the documented callers; egress only to DNS, documented dependencies and Alloy) |
| Config | `env` map (templated with `tpl`), `secretEnv` for credentials, shared `global.monitoring` endpoints, downward-API `OTEL_RESOURCE_ATTRIBUTES` |
| Telemetry | OTLP/gRPC to Alloy for traces/metrics/logs, Pyroscope push for profiles — no scrape config needed |
| Admission | In the cluster, Kyverno additionally requires: known app name bound to its own ServiceAccount, allowed registries + digest + our cosign signature, read-only root FS, requests/limits, probes, no API token (`policies/README.md`) |
| Hygiene | `app.kubernetes.io/*` labels, `values.schema.json`, `NOTES.txt`, image precedence `digest > tag > appVersion`, `global.imageRegistry` |

| Chart | Kind | Port | Called by | Calls |
|---|---|---|---|---|
| frontend | Deployment | 8080 (svc 80) | ingress | product-catalog, currency, cart, recommendation, checkout, shipping, ad |
| ad-service | Deployment | 9555 | frontend | — |
| cart-service | Deployment | 7070 | frontend, checkout | cart-redis |
| checkout-service | Deployment | 5050 | frontend | product-catalog, cart, currency, shipping, payment, email |
| currency-service | Deployment | 7000 | frontend, checkout | — |
| email-service | Deployment | 8080 | checkout | — |
| payment-service | Deployment | 50051 | checkout | — |
| product-catalog-service | Deployment | 3550 | frontend, checkout, recommendation | product-catalog-db |
| recommendation-service | Deployment | 8080 | frontend | product-catalog |
| shipping-service | Deployment | 50051 | frontend, checkout | — |
| product-catalog-db | StatefulSet | 5432 | product-catalog-service | — |
| cart-redis | StatefulSet | 6379 | cart-service | — |

Resource names equal the chart names on purpose: they are the DNS names the services are configured with (`cart-service:7070`, …). Install everything into one namespace, or override every `*_ADDR` with an FQDN.

## Configuring

- **Credentials:** `product-catalog-db.auth.existingSecret` (keys `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`) or `product-catalog-db.auth.password` (alphanumeric). The install fails if neither is set. `product-catalog-service` reads the same Secret and builds `DATABASE_URL` from it.
- **Monitoring endpoints:** `global.monitoring.otlpEndpoint`, `global.monitoring.pyroscopeAddr`, `global.monitoring.namespace` (NetworkPolicy egress target).
- **Images:** `<chart>.image.tag` / `.digest`; `global.imageRegistry` prefixes all of them.
- **Ingress (frontend):** `frontend.ingress.*` — use TLS, the cookies are `Secure`.
- **Scaling profile:** see `platform-demo/values-dev.yaml` (small) and `values-prod.yaml` (ingress + TLS + hard per-node spread).

## Develop

```bash
helm lint <chart>                                            # or loop over */
helm template <app> <chart> -n dev-platform-demo -f envs/common.yaml -f envs/dev/common.yaml -f envs/dev/values/<app>.yaml
python3 .github/scripts/render-envs.py /tmp/rendered         # every app of every environment and the platform, as Argo CD renders them, plus the wiring checks
helm dependency update <chart>                               # after changing platform-common
```

Charts and the library share a version contract: bump `platform-common` and re-run `helm dependency update` in every chart that should pick it up (Argo CD runs `helm dependency build` itself; `Chart.lock` files are committed, the vendored `charts/*.tgz` are not).

The pull-request pipeline (`.github/workflows/ci.yaml`; the only workflows that run on push are the promotion chain and the stage release): helm lint of every chart, render of the umbrella and of every shop and platform app, kubeconform (strict, Kubernetes + CRD schemas incl. Cilium/Gateway API/Argo CD), Trivy config scan (rendered charts must be clean), a cosign gate (every deployed `mladenovskistefan/*` image pinned by digest and signed by an allowed workflow, `verifyImages.signers`), **Kyverno policy tests** (unit tests for every policy, then every rendered workload/add-on of every environment is evaluated against the policies, so a chart change that admission would refuse fails the PR), the promotion policy, secret scan and workflow lint. All jobs run in parallel on every pull request and a final **`gate`** job, the only required status check, fails when any of them failed, was cancelled or was skipped without a reason ([docs/promote.md](docs/promote.md)).

## Status

The target is the EKS cluster created by [infra-terraform](https://github.com/platform-boutique/infra-terraform); the charts, policies and CI in this repository are rendered and checked on every pull request (helm lint, kubeconform, Trivy, cosign, Kyverno tests). Nothing here has been verified on EKS yet: the end-to-end run is still to be done and will be recorded here.
