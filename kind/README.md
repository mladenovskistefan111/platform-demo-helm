# Local kind cluster with Gateway API

Everything is reachable on `127.0.0.1:80/443` through an Envoy Gateway (Gateway API), HTTPS only (the shop's cookies are `Secure`).

| URL | What |
|---|---|
| https://shop.platform-demo.test | the Online Boutique frontend |
| https://grafana.platform-demo.test | Grafana (anonymous Admin, local only) with the 10 service dashboards |

## Hostnames to add

Both names must resolve to `127.0.0.1`.

- **Windows browser (WSL2):** edit `C:\Windows\System32\drivers\etc\hosts` as Administrator and add
  ```
  127.0.0.1 shop.platform-demo.test grafana.platform-demo.test
  ```
- **Inside WSL / Linux (curl, etc.):** the same line in `/etc/hosts`.

Optional, to remove the certificate warning: trust `kind/certs/ca.crt` (Windows: double-click, install into *Trusted Root Certification Authorities*).

## Create / destroy

```bash
cd platform-demo-helm
kind create cluster --config kind/cluster.yaml
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.5.0 -n envoy-gateway-system --create-namespace --wait

kubectl create ns platform-demo && kubectl label ns platform-demo pod-security.kubernetes.io/enforce=restricted
kubectl create ns monitoring
helm upgrade --install monitoring monitoring-local -n monitoring --set grafana.rootUrl=https://grafana.platform-demo.test
helm upgrade --install platform-demo platform-demo -n platform-demo -f platform-demo/values-dev.yaml -f platform-demo/values-kind.yaml

DOMAIN=platform-demo.test bash kind/make-tls.sh            # local CA + wildcard cert -> Secret gateway-system/platform-tls
helm upgrade --install platform-gateway platform-gateway -n gateway-system

kind delete cluster --name platform-local
```

Install order matters only for the Gateway (needs Envoy Gateway's CRDs and the TLS Secret); apps and monitoring can start in parallel.

## Notes

- The proxy Service is a `NodePort` (30080/30443) that `kind/cluster.yaml` maps to the host loopback; change `domain` in `platform-gateway/values.yaml` and re-run `make-tls.sh` to use other names.
- `monitoring-local` is a throw-away, single-replica stack (emptyDir storage, anonymous Grafana admin). For real clusters use `monitoring/`.
- `platform-demo/values-kind.yaml` lets the frontend NetworkPolicy accept traffic from the Envoy proxy namespace.
