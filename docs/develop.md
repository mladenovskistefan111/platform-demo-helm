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
helm template <app> <chart> -n dev-platform-demo -f envs/common.yaml -f envs/dev/common.yaml -f envs/dev/values/<app>.yaml
python3 .github/scripts/render-envs.py /tmp/rendered         # every shop app of every environment and the platform, as Argo CD renders them, plus the wiring checks
helm dependency update <chart>                               # after changing platform-common
```

Charts and the library share a version contract: bump `platform-common` and re-run `helm dependency update` in every chart that should pick it up (Argo CD runs `helm dependency build` itself; `Chart.lock` files are committed, the vendored `charts/*.tgz` are not).

The pull-request pipeline (`.github/workflows/ci.yaml`, nothing runs on push): helm lint of every chart, render of the umbrella and of every shop and platform app, kubeconform (strict, Kubernetes + CRD schemas incl. Cilium/Gateway API/Argo CD), Trivy config scan (rendered charts must be clean), a cosign gate (every deployed `mladenovskistefan/*` image pinned by digest and signed), **Kyverno policy tests** (unit tests for every policy, then every rendered workload/add-on of every environment is evaluated against the policies, so a chart change that admission would refuse fails the PR), secret scan and workflow lint.

## Status

The target is the EKS cluster created by infra-terraform; the charts, policies and CI are checked on every pull request. Nothing here has been verified on EKS yet: the end-to-end run is still to be done and will be recorded here.
