# platform-demo-helm

Helm charts for the platform-demo application (the 10 services plus PostgreSQL and Redis). `product-catalog-db` is a **temporary** chart/image for local testing; on AWS the database is RDS and that chart is removed. The observability stack (Alloy, Mimir, Loki, Tempo, Pyroscope, Grafana) is deployed separately — see `monitoring/`.

Context for everything below lives in the master [`../README.md`](../README.md) (architecture, wiring, observability contract, gotchas).

## Layout

```
platform-common/          library chart (templates only, no resources of its own)
platform-demo/            umbrella chart: one `helm install` for the whole app
                          values.yaml · values-dev.yaml · values-prod.yaml
ad-service/  cart-service/  checkout-service/  currency-service/  email-service/
frontend/  payment-service/  product-catalog-service/  recommendation-service/  shipping-service/   Deployments
product-catalog-db/  cart-redis/                                                                      StatefulSets
monitoring/               vendored upstream charts (unchanged)
```

Every service chart is ~6 tiny template files that call into `platform-common` (`{{ include "platform-common.deployment" . }}` …) plus a fully commented `values.yaml`, so behaviour is identical everywhere and a fix in the library reaches all charts.

## Quick start

```bash
kubectl create namespace platform-demo
kubectl label ns platform-demo pod-security.kubernetes.io/enforce=restricted   # the charts comply

cd platform-demo
helm dependency update                                   # vendors the sub-charts (already done once)

# laptop / kind: 1 replica each, no HPA/PDB, demo DB password
helm upgrade --install platform-demo . -n platform-demo -f values-dev.yaml

# HA defaults (2 replicas, HPA, PDB, topology spread); needs metrics-server
helm upgrade --install platform-demo . -n platform-demo \
  --set product-catalog-db.auth.existingSecret=product-catalog-db-credentials

kubectl -n platform-demo port-forward svc/frontend 8080:80    # http://localhost:8080
```

Prerequisites: the service images on Docker Hub (`mladenovskistefan/<service>`, pinned by `image.digest` in each chart; built, scanned and cosign-signed by each service's `CI - Main`), the monitoring stack reachable at `alloy.monitoring.svc.cluster.local` (or `--set global.monitoring.*`), a CNI that enforces NetworkPolicy, and HTTPS in front of the frontend for real use.

Install one service alone:

```bash
cd checkout-service && helm dependency update
helm upgrade --install checkout-service . -n platform-demo
```

## What each chart provides

| | |
|---|---|
| Workload | `Deployment` (or `StatefulSet` for the two stores), RollingUpdate with `maxUnavailable: 0`, `minReadySeconds`, `revisionHistoryLimit` |
| Scaling | `HorizontalPodAutoscaler` v2 (CPU 70 %, scale-down stabilisation 300 s), replicas owned by the HPA when enabled |
| Availability | `PodDisruptionBudget` (`maxUnavailable: 1`, `AlwaysAllow` for unhealthy pods), soft topology spread, `preStop` sleep, per-service termination grace |
| Probes | startup / readiness / liveness (native `grpc` probes for gRPC services, `httpGet` for the frontend, `exec` for Postgres/Redis) |
| Resources | requests + limits for every container (sized from measured usage) |
| Security | restricted Pod Security profile: non-root numeric UID/GID, read-only root FS with explicit `/tmp`, no privilege escalation, all capabilities dropped, `RuntimeDefault` seccomp, no ServiceAccount token, no service links |
| Network | `NetworkPolicy`: ingress only from the documented callers; egress only to DNS, documented dependencies and Alloy |
| Config | `env` map (templated with `tpl`), `secretEnv` for credentials, shared `global.monitoring` endpoints, downward-API `OTEL_RESOURCE_ATTRIBUTES` |
| Telemetry | OTLP/gRPC to Alloy for traces/metrics/logs, Pyroscope push for profiles — no scrape config needed |
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
helm lint platform-common platform-demo ad-service ...        # or loop over */
helm template platform-demo platform-demo -n platform-demo -f platform-demo/values-dev.yaml | less
helm dependency update <chart>   # after changing platform-common
```

Charts and the library share a version contract: bump `platform-common` and re-run `helm dependency update` in every chart that should pick it up (the umbrella vendors the service charts the same way).

## Verified

On a throw-away kind cluster (1 control-plane + 2 workers, Kubernetes 1.32, metrics-server): clean install in under a minute with zero restarts, a full browse → cart → checkout, NetworkPolicy enforcement (allowed and blocked paths), telemetry reaching the collector, the `restricted` Pod Security Standard enforced on the namespace through a full rollout restart, and HPAs scaling out under load. Details in master README §8.5.
