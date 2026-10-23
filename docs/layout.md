# Repository layout

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
