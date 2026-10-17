# Configure, develop, verify

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

The pull-request pipeline (`.github/workflows/ci.yaml`, nothing runs on push): helm lint of every chart, render of the umbrella and of every env app, kubeconform (strict, Kubernetes + CRD schemas incl. Cilium/Gateway API/Argo CD), Trivy config scan (app charts must be clean, `monitoring-local` is report-only), a cosign gate (every deployed `mladenovskistefan/*` image pinned by digest and signed), **Kyverno policy tests** (unit tests for every policy, then every rendered workload/add-on of every environment is evaluated against the policies, so a chart change that admission would refuse fails the PR), secret scan and workflow lint.

## Verified

2026-10-17 on a single-node kind cluster (Kubernetes 1.32) with **Cilium 1.20.2** (kube-proxy replacement, Gateway API, Hubble, SPIRE mutual authentication): `kind/up.sh` from scratch, 16 Argo CD Applications Synced/Healthy, browse -> cart -> checkout through the Cilium Gateway over HTTPS ("Your order is complete!"), telemetry from all ten services in Mimir/Tempo/Loki, default-deny proven with an intruder pod, mutual authentication proven with a new identity that cannot connect while SPIRE is down. Earlier (kubeadm-style kind, 3 nodes, metrics-server) verification of HPA/PDB/NetworkPolicy is in master README §8.5.
