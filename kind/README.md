# Local environment: kind + Cilium + Argo CD

One command builds a production-shaped cluster on a laptop; Argo CD then deploys everything from this repository.

```bash
kind/up.sh      # ~10-15 min the first time (image pulls)
kind/down.sh    # delete the cluster; kind/certs/ (local CA) is kept
```

Requirements: `docker`, `kind` (0.27+), `kubectl`, `helm` 3.x, `openssl`; about 6 GB of free RAM (the whole stack used ~4.8 GB of a 7.5 GB WSL2 VM).

## What you get

| URL | What |
|---|---|
| https://shop.platform-demo.test | the Online Boutique frontend |
| https://argocd.platform-demo.test | Argo CD (user `admin`; password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d`) |
| https://grafana.platform-demo.test | Grafana (anonymous Admin, local only) with the 10 service dashboards |
| https://hubble.platform-demo.test | Hubble UI: live flows, policy verdicts, authentication |

**Hostnames** must resolve to `127.0.0.1`: add `127.0.0.1 shop.platform-demo.test grafana.platform-demo.test argocd.platform-demo.test hubble.platform-demo.test` to `C:\Windows\System32\drivers\etc\hosts` (Administrator) and to WSL `/etc/hosts`. Trust `kind/certs/ca.crt` (Windows: double-click -> Trusted Root Certification Authorities) to remove the certificate warning. HTTPS is mandatory: the frontend's cookies are `Secure`.

## What `up.sh` does, in order

1. **kind** cluster `platform-local` (`cluster.yaml`): one node, **no default CNI, no kube-proxy**, host ports 80/443 mapped to 8080/8443 on the node.
2. **Gateway API CRDs** v1.6.3 (must exist before Cilium starts).
3. **Cilium 1.20.2** (`cilium-values.yaml`): CNI, eBPF kube-proxy replacement, **Gateway API in host-network mode** (no LoadBalancer on kind; listeners 8080/8443), Hubble (+ UI), **mutual authentication with the bundled SPIRE** (persistent 1 Gi PVC for the SPIRE CA).
4. Waits for SPIRE, then restarts the Cilium operator/agents once so they pick up their SPIFFE identities.
5. **TLS**: `make-tls.sh` creates a local CA + wildcard certificate -> Secret `gateway-system/platform-tls`.
6. Namespace `platform-demo` (Pod Security `restricted`) and the **DB credentials Secret with a random password** - the only things that must not live in Git.
7. **Argo CD** (`argo/argo-cd`, values from `../gitops/argocd/values.yaml`).
8. `kubectl apply -f gitops/bootstrap/root.yaml`: the root Application. From here Argo CD creates the projects, the ApplicationSets, itself (self-management) and the 14 Applications (12 workloads + `platform-gateway` + `monitoring-local`). See `../gitops/README.md`.

## Day-to-day

```bash
kubectl -n argocd get applications                     # everything should be Synced / Healthy
kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --namespace platform-demo --last 30
kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --verdict DROPPED --last 20
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf auth list          # authenticated pairs
kubectl -n cilium-spire exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show -socketPath /tmp/spire-server/private/api.sock
```

To try a branch before merging, point every Git reference under `gitops/` (`targetRevision:` / `revision:`) at the branch in a throw-away commit, `kubectl apply -f gitops/bootstrap/root.yaml`, and revert the commit before the PR.

## Gotchas found while building this (read before changing anything here)

- **SPIRE 1.15 image vs the Cilium chart.** The image runs as uid 1000, which breaks the chart twice: the admin-socket `hostPath` is created `root:root 0755` ("bind: permission denied", and SPIRE 1.15 then *hangs* instead of exiting), and the `cilium-init` sidecar registers identities through `/proc/<pid>/root` of the server, which needs `CAP_SYS_PTRACE` across users. Symptom: every connection dropped with `Authentication required`, Cilium logs `no SPIFFE ID for spiffe://spiffe.cilium/identity/N`, `spire-server entry show` -> `Found 0 entries`. Fix (in `cilium-values.yaml`): run the SPIRE server as root.
- **A new identity needs ~10-15 s** before it can talk (the operator registers it with SPIRE, the entry propagates to the node agent). The first connection attempts of a brand-new workload are dropped with `Authentication required`, then it works; gRPC clients and init containers retry.
- **After recreating SPIRE's storage** (new CA) restart `ds/spire-agent`, then `deploy/cilium-operator` and `ds/cilium`. A plain SPIRE server *pod* restart with the PVC needs nothing.
- **Mutual auth is label-based identity.** A pod that carries an allowed label (e.g. `app.kubernetes.io/name: frontend`) *is* that workload as far as Cilium is concerned. Controlling who may create pods with those labels is Kyverno/RBAC's job.
- **The Cilium Gateway is "ingress" entity traffic**, not a pod: policies allow it with `fromEntities: [ingress]` (see `envs/dev/values/frontend.yaml`), not with namespace selectors.
- **No metrics-server on kind** -> HPAs would show `<unknown>` and make Argo CD report the apps Degraded. The dev profile (`envs/dev/values/common.yaml`) disables HPA/PDB and runs 1 replica.
- **Argo CD server-side diff** (`controller.diff.server.side`) is required, otherwise Gateway API routes and StatefulSets stay OutOfSync forever (the API server defaults fields the manifests don't set). It is read at start-up: restart `argocd-application-controller` after changing it by hand.
- **musl + search domains:** if the host injects a DNS search domain (a VPN/company domain did here), names with fewer than 5 dots are first tried with the search domains and Alpine/musl fails with `EAI_AGAIN`; the charts set `dnsConfig.ndots: 2`. Symptom: `StatusCode.UNAVAILABLE ... alloy` in app logs.
- `kind load docker-image` fails on this machine (`ctr ... content digest not found`); let the node pull from Docker Hub.
- Mimir as non-root needs `workingDir: /data` and `-activity-tracker.filepath=/data/metrics-activity.log`; `limits.out_of_order_time_window: 5m` removes duplicate `target_info` rejections.
- The old kind cluster `platform-demo` (from before this setup) cannot start (`docker start` fails with a systemd/cgroup scope error). Remove it with `kind delete cluster --name platform-demo`.

## Notes

- `monitoring-local` is a throw-away, single-replica stack (emptyDir storage, anonymous Grafana admin, no network policies). For real clusters use `../monitoring/`.
- Cilium itself is installed by `up.sh`, not by Argo CD (Argo CD needs a CNI to exist). Adopting it into GitOps afterwards is possible and listed as a next step in `../HANDOFF.md`.
- Mutual authentication is Beta in Cilium, and the SPIFFE handshake authenticates; it does **not** encrypt the data path (WireGuard/IPsec would, and are not enabled).
