# Deploy

The target is an **EKS** cluster whose infrastructure (VPC, cluster, Cilium, nodes, ALB, DNS) is created by the
[infra-terraform](https://github.com/platform-boutique/infra-terraform) repository. This repository is everything that runs *on* the cluster, and Argo CD applies it.

1. Terraform creates the cluster with Cilium (CNI, kube-proxy replacement, Gateway API in host-network mode) and the ALB in front of it.
2. Bootstrap Argo CD once: install the `argo/argo-cd` chart with `gitops/argocd/values.yaml`, then `kubectl apply -f gitops/bootstrap/root.yaml`.
   From there Argo CD creates the projects, the ApplicationSets, itself, Kyverno and the policies, and one Application per entry of `envs/dev/`. See [GitOps](gitops.md).
3. Secrets are not in Git. They live in AWS Systems Manager Parameter Store (`/platform-demo/...`) and reach the cluster through External Secrets
   (see `secrets.md` in infra-terraform).
4. The hostnames are `argocd`, `backstage`, `grafana`, `dex`, `hubble` and `shop` under `platform-demo.click`; people sign in with GitHub through Dex.

## Without Argo CD

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
