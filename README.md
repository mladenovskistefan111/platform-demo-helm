# platform-demo-helm

Everything that is deployed: the Helm charts for the platform-demo application (10 services, PostgreSQL, Redis), the Gateway API entry point, and the **GitOps configuration** that makes Argo CD deploy them. This repository is the single source of truth for what runs in each environment; the service repositories only build and publish images.

Context for everything below lives in the [docs repo](https://github.com/platform-boutique/platform-demo-docs): the master [`README.md`](https://github.com/platform-boutique/platform-demo-docs/blob/main/README.md) (architecture, wiring, observability contract, CI/CD model, gotchas) and the session handoff [`HANDOFF.md`](https://github.com/platform-boutique/platform-demo-docs/blob/main/HANDOFF.md).

> `product-catalog-db` is a **temporary** chart/image (kept as a StatefulSet for now). The target database is RDS, and then that chart (plus its allow-list entry in `.github/workflows/ci.yaml`) is deleted.

## How it fits together

```
service repos  --release tag-->  Docker Hub (signed image, digest)
                                        |  PR: bump image.digest in envs/<env>/values/<app>.yaml
                                        v
platform-demo-helm  (this repo, main)  <--- Argo CD polls --- ApplicationSets (gitops/apps)
   charts + envs/ + gitops/                                      |
                                                                  v
                                                  one Application per (env, app) -> cluster
```

- **Charts** (`<service>/`, `platform-common/`, `platform-gateway/`, `dex/`, `backstage/`) describe *how* something is deployed.
- **`envs/<env>/`** describes *what* runs in an environment: `workloads.yaml` / `addons.yaml` (lists) and `values/<app>.yaml` (image digest, per-env settings). **Promotion = a pull request that changes a digest.**
- **`gitops/`** is Argo CD's own configuration: install values, the root Application, projects, the two ApplicationSets and the Kyverno Applications. See [`gitops/README.md`](gitops/README.md).
- **`policies/`** are the Kyverno admission policies (identity, images and signatures, pod hardening, exposure, break-glass, namespace baseline). See [`policies/README.md`](policies/README.md).

## Layout

```
platform-common/          library chart (templates only): Deployment, StatefulSet, Service, HPA, PDB, NetworkPolicy and
                          CiliumNetworkPolicy (networkPolicy.type), probes, security context helpers
<service>/                10 Deployments + product-catalog-db / cart-redis StatefulSets; thin charts over platform-common
platform-gateway/         Gateway (Cilium GatewayClass), HTTP->HTTPS redirect and HTTPRoutes: shop, grafana, argocd, hubble, backstage, dex
monitoring/               vendored upstream charts (unchanged; not deployed by envs/dev yet)
dex/, backstage/          single sign-on and the developer portal
platform-demo/            umbrella chart: `helm install` of the whole app without Argo CD (values-dev/prod.yaml)
envs/dev/                 workloads.yaml, addons.yaml, values/<app>.yaml, values/common.yaml
gitops/                   argocd/values.yaml, kyverno/values.yaml, bootstrap/root.yaml, apps/ (AppProjects, ApplicationSets, Argo CD and Kyverno Applications)
policies/                 Kyverno policies (CEL policy types) + tests; README explains each policy, rollout, exceptions, break-glass
.github/                  ci.yaml (PR gate), scripts/ (render-envs.py, policy-check.sh, inject-namespaces.py), CODEOWNERS, dependabot.yml
```

Every service chart is ~6 tiny template files that call into `platform-common` plus a fully commented `values.yaml`, so behaviour is identical everywhere and a fix in the library reaches all charts.

## Deploy

The target is an **EKS** cluster whose infrastructure (VPC, cluster, Cilium, nodes, ALB, DNS) is created by the
[infra-terraform](https://github.com/platform-boutique/infra-terraform) repository. This repository is everything that runs *on* the cluster, and Argo CD applies it.

1. Terraform creates the cluster with Cilium (CNI, kube-proxy replacement, Gateway API in host-network mode) and the ALB in front of it.
2. Bootstrap Argo CD once: install the `argo/argo-cd` chart with `gitops/argocd/values.yaml`, then `kubectl apply -f gitops/bootstrap/root.yaml`.
   From there Argo CD creates the projects, the ApplicationSets, itself, Kyverno and the policies, and one Application per entry of `envs/dev/`. See [`gitops/README.md`](gitops/README.md).
3. Secrets are not in Git. They live in AWS Systems Manager Parameter Store (`/platform-demo/...`) and reach the cluster through External Secrets
   (see `secrets.md` in infra-terraform).
4. The hostnames are `argocd`, `backstage`, `grafana`, `dex`, `hubble` and `shop` under `platform-demo.click`; people sign in with GitHub through Dex.

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

Prerequisites either way: the service images on Docker Hub (pinned by digest, built/scanned/signed by each service's `release.yaml`), the monitoring
stack reachable at `alloy.monitoring.svc.cluster.local` (or `--set global.monitoring.*`), and HTTPS in front of the frontend (its cookies are `Secure`).

## Promote an image

1. A service repo tagged `vX.Y.Z` and its `release.yaml` published `mladenovskistefan/<svc>:X.Y.Z` (signed). Get the digest: `docker buildx imagetools inspect mladenovskistefan/<svc>:X.Y.Z` (the `Digest:` line).
2. Open a PR changing `image.digest` in `envs/<env>/values/<svc>.yaml`.
3. CI renders the app exactly as Argo CD will, validates it (kubeconform with CRD schemas, Trivy config) and **verifies the digest is signed by one of our pipelines**. Merge -> Argo CD syncs within ~2 minutes.

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
helm template <app> <chart> -n platform-demo -f envs/dev/values/common.yaml -f envs/dev/values/<app>.yaml
python3 .github/scripts/render-envs.py /tmp/rendered         # all apps of all envs, as Argo CD renders them
helm dependency update <chart>                               # after changing platform-common
```

Charts and the library share a version contract: bump `platform-common` and re-run `helm dependency update` in every chart that should pick it up (Argo CD runs `helm dependency build` itself; `Chart.lock` files are committed, the vendored `charts/*.tgz` are not).

The pull-request pipeline (`.github/workflows/ci.yaml`, nothing runs on push): helm lint of every chart, render of the umbrella and of every env app, kubeconform (strict, Kubernetes + CRD schemas incl. Cilium/Gateway API/Argo CD), Trivy config scan (rendered charts must be clean), a cosign gate (every deployed `mladenovskistefan/*` image pinned by digest and signed), **Kyverno policy tests** (unit tests for every policy, then every rendered workload/add-on of every environment is evaluated against the policies, so a chart change that admission would refuse fails the PR), secret scan and workflow lint.

## Status

The target is the EKS cluster created by [infra-terraform](https://github.com/platform-boutique/infra-terraform); the charts, policies and CI in this repository are rendered and checked on every pull request (helm lint, kubeconform, Trivy, cosign, Kyverno tests). Nothing here has been verified on EKS yet: the end-to-end run is still to be done and will be recorded here.
