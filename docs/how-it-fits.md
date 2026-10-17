# How it fits together

```
service repos  --release tag-->  Docker Hub (signed image, digest)
                                        |  PR: bump image.digest in envs/<env>/values/<app>.yaml
                                        v
platform-demo-helm  (this repo, main)  <--- Argo CD polls --- ApplicationSets (gitops/apps)
   charts + envs/ + gitops/                                      |
                                                                  v
                                                  one Application per (env, app) -> cluster
```

- **Charts** (`<service>/`, `platform-common/`, `platform-gateway/`, `monitoring-local/`) describe *how* something is deployed.
- **`envs/<env>/`** describes *what* runs in an environment: `workloads.yaml` / `addons.yaml` (lists) and `values/<app>.yaml` (image digest, per-env settings). **Promotion = a pull request that changes a digest.**
- **`gitops/`** is Argo CD's own configuration: install values, the root Application, projects, the two ApplicationSets and the Kyverno Applications. See [`gitops/README.md`](https://github.com/platform-boutique/platform-demo-helm/blob/main/gitops/README.md).
- **`policies/`** are the Kyverno admission policies (identity, images and signatures, pod hardening, exposure, break-glass, namespace baseline). See [`policies/README.md`](https://github.com/platform-boutique/platform-demo-helm/blob/main/policies/README.md).
