# Promote an image

1. A service repo tagged `vX.Y.Z` and its `release.yaml` published `mladenovskistefan/<svc>:X.Y.Z` (signed). Get the digest: `docker buildx imagetools inspect mladenovskistefan/<svc>:X.Y.Z` (the `Digest:` line).
2. Open a PR changing `image.digest` in `envs/<env>/values/<svc>.yaml`.
3. CI renders the app exactly as Argo CD will, validates it (kubeconform with CRD schemas, Trivy config) and **verifies the digest is signed by one of our pipelines**. Merge -> Argo CD syncs within ~2 minutes.
