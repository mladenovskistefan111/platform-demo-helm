# Repository layout

```
platform-common/          library chart (templates only): Deployment, StatefulSet, Service, HPA, PDB, NetworkPolicy and
                          CiliumNetworkPolicy (networkPolicy.type), probes, security context helpers
<service>/                10 Deployments + product-catalog-db / cart-redis StatefulSets; thin charts over platform-common
platform-gateway/         Gateway (Cilium GatewayClass, plain HTTP on 8080 behind the ALB) and HTTPRoutes: shop, argocd, hubble, backstage, dex
cluster-bootstrap/        namespaces with their labels (Pod Security, Kyverno profile, gVisor), RuntimeClass gvisor, the one-off SPIRE/Cilium restart Job
platform-network-policies/ default-deny and allow rules (CiliumNetworkPolicy) for argocd, sso, backstage, gateway-system
monitoring-local/         single-replica Alloy, Mimir, Loki, Tempo, Pyroscope, Grafana for laptops (not for real clusters)
monitoring/               vendored upstream charts (unchanged), for real clusters
platform-demo/            umbrella chart: `helm install` of the whole app without Argo CD (values-dev/prod/kind.yaml)
envs/dev/                 workloads.yaml, addons.yaml, values/<app>.yaml, values/common.yaml, values/cluster-bootstrap.yaml (the namespace list)
gitops/                   app-of-apps: bootstrap/root.yaml (Terraform mirrors it), apps/ (AppProjects + one Application per layer), layers/{bootstrap,security,platform,workloads}/ (sync-wave ordered Applications and ApplicationSets), argocd/values.yaml, kyverno/values.yaml
policies/                 Kyverno policies (CEL policy types) + tests; README explains each policy, rollout, exceptions, break-glass
kind/                     up.sh / down.sh, cluster.yaml, cilium-values.yaml, make-tls.sh, README.md (runbook)
.github/                  ci.yaml (PR gate), scripts/ (render-envs.py, policy-check.sh, inject-namespaces.py), CODEOWNERS, dependabot.yml
```

Every service chart is ~6 tiny template files that call into `platform-common` plus a fully commented `values.yaml`, so behaviour is identical everywhere and a fix in the library reaches all charts.
