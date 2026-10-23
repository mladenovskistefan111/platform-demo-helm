# How it fits together

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
- **`envs/<env>/`** (`dev`, `stage`, `prod`) is the shop only, three environments on one cluster: `workloads.yaml` (the app list) and `values/<app>.yaml` (image tag + digest, per-env settings); `envs/common.yaml` holds the defaults every environment shares. **Promotion = a pull request that changes a digest.** See [Environments](environments.md).
- **`clusters/<cluster>/`** (`main` today) is everything that is not the shop: `addons.yaml` and `values/<name>.yaml` for the add-ons and the cluster-wide charts (namespace list, policies, external-secrets-config). A later management/app cluster split adds a directory here.
- **`gitops/`** is Argo CD's own configuration: install values, the root Application, projects, the two ApplicationSets and the Kyverno Applications. See [`gitops/README.md`](https://github.com/platform-boutique/platform-demo-helm/blob/main/gitops/README.md).
- **`policies/`** are the Kyverno admission policies (identity, images and signatures, pod hardening, exposure, break-glass, namespace baseline). See [`policies/README.md`](https://github.com/platform-boutique/platform-demo-helm/blob/main/policies/README.md).
