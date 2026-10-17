# Quick start

```bash
kind/up.sh        # kind + Cilium + Gateway API + Argo CD, then Argo CD deploys the rest from Git (~10-15 min)
kind/down.sh      # destroys the cluster
```

Needs `docker`, `kind`, `kubectl`, `helm`, `openssl`, ~6 GB free RAM. The script prints the URLs and the hosts-file line (`shop|grafana|argocd|hubble.platform-demo.test`). Full explanation and troubleshooting: [`kind/README.md`](https://github.com/platform-boutique/platform-demo-helm/blob/main/kind/README.md).

Without Argo CD (any cluster with a CNI that enforces NetworkPolicy):

```bash
kubectl create namespace platform-demo
kubectl label ns platform-demo pod-security.kubernetes.io/enforce=restricted   # the charts comply
cd platform-demo && helm dependency update
helm upgrade --install platform-demo . -n platform-demo -f values-dev.yaml          # laptop profile, demo DB password
helm upgrade --install platform-demo . -n platform-demo \
  --set product-catalog-db.auth.existingSecret=product-catalog-db-credentials        # HA defaults, needs metrics-server
```

Prerequisites either way: the service images on Docker Hub (pinned by digest, built/scanned/signed by each service's `release.yaml`), the monitoring stack reachable at `alloy.monitoring.svc.cluster.local` (or `--set global.monitoring.*`), and HTTPS in front of the frontend (its cookies are `Secure`).
