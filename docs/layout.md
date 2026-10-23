# Repository layout

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
