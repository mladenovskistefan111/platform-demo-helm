# GitOps: how Argo CD deploys this repository

After `terraform apply` the cluster contains Cilium (with SPIRE mutual authentication and WireGuard), the EBS CSI driver, CoreDNS, a default `gp3` StorageClass, the namespaces `argocd` and `external-secrets`, **Argo CD** (chart `argo/argo-cd` 10.10.0, bootstrap values only), and two objects Terraform creates from [`bootstrap/root.yaml`](bootstrap/root.yaml): the AppProject `platform-admin` and the Application `platform-root`. **Everything else comes from this repository**, through an app-of-apps with four layers. Nothing is applied by hand.

```
platform-root  (Terraform; path gitops/apps)
 |-- AppProjects (wave -10): platform-admin, bootstrap, secrets, security, platform, workloads
 |-- layer-bootstrap  (wave 0)   gitops/layers/bootstrap
 |     `-- cluster-bootstrap          namespaces + labels, RuntimeClass gvisor, one-off Job: restart Cilium after SPIRE
 |-- layer-security   (wave 10)  gitops/layers/security
 |     |-- external-secrets  (0) -> external-secrets-config (10) + reloader (10) -> kyverno (20) -> dev-policies (30)
 |-- layer-platform   (wave 20)  gitops/layers/platform
 |     |-- platform-network-policies (0) -> platform-addons ApplicationSet (10) -> argocd (20)
 |     |                                     `-- dev-platform-gateway, dev-dex, dev-backstage   (envs/dev/addons.yaml)
 `-- layer-workloads  (wave 20)  gitops/layers/workloads
       `-- platform-workloads ApplicationSet -> dev-<service> x 12   (envs/dev/workloads.yaml)
```

## Layers, waves, why this order

Sync waves order the Applications *inside* one parent: Argo CD syncs a wave, waits until everything in it is Healthy (a child Application is healthy when its resources are), then starts the next. Layer Applications are the unit of ordering; waves inside a layer order its Applications.

| Layer / wave | Application | Project | What it is | Why here |
|---|---|---|---|---|
| bootstrap / 0 | `cluster-bootstrap` | `bootstrap` | Chart `cluster-bootstrap/` with `envs/dev/values/cluster-bootstrap.yaml`: every Namespace with its Pod Security, Kyverno-profile and gVisor labels (wave -10), RuntimeClass `gvisor` (-5), and the Job `spire-cilium-restart` (5) | Namespaces must exist, labelled, before secrets, policies or apps; the RuntimeClass before the first sandboxed pod; Cilium must restart once SPIRE runs, before any pod needs mutual authentication |
| security / 0 | `external-secrets` | `secrets` | External Secrets Operator (chart 2.11.0) | CRDs and webhook first |
| security / 10 | `external-secrets-config`, `reloader` | `secrets` | ClusterSecretStore + ExternalSecrets (`sso/dex-secrets`, `backstage/backstage-secrets`, `argocd/argocd-oidc`, `kyverno/dockerhub-read`, the shop's DB credentials), Reloader | An ExternalSecret is Healthy only once its Secret exists, so the next wave cannot start without them |
| security / 20 | `kyverno` | `security` | Kyverno 1.19 (chart 3.9.1), 2 admission replicas on the host network | After `kyverno/dockerhub-read` exists ("Kyverno waits for it") |
| security / 30 | `dev-policies` | `security` | Chart `policies/` (enforcing: workload scope; reporting: platform scope), incl. the gVisor mutation | Needs the Kyverno CRDs |
| platform / 0 | `platform-network-policies` | `platform` | Default-deny + allow rules for argocd, sso, backstage, gateway-system | Rules exist before the pods |
| platform / 10 | ApplicationSet `platform-addons` | `platform` | `dev-platform-gateway`, `dev-dex`, `dev-backstage` | Admission control and secrets are in place |
| platform / 20 | `argocd` | `platform-admin` | Argo CD managing itself from `argocd/values.yaml` (admin off, Dex SSO) | Last on purpose: `admin.enabled=false` is applied only after the `argocd-oidc` Secret exists and Dex was deployed |
| workloads / 20 | ApplicationSet `platform-workloads` | `workloads` | The shop: 10 services, `product-catalog-db` and `cart-redis` StatefulSets | Needs security (policies, mutation, secrets) but not Dex/Backstage, hence the same wave as platform: a missing GitHub OAuth parameter must not keep the shop from deploying |

Generated Applications (ApplicationSets) cannot be ordered against each other - the controller creates them, a sync does not - so the shop's services and the add-ons rely on retries until their dependencies are up (as before).

**Projects (least privilege).** `platform-admin` (Argo CD itself and the layer definitions, cluster-admin, unchanged and mirrored by Terraform), `bootstrap` (Namespace, RuntimeClass, one Job and two Roles), `secrets` (the two operators, CRDs and webhooks), `security` (Kyverno and the policies), `platform` (namespaced add-on resources and the two ClusterRoles Dex/Backstage need; **no Namespace rights**), `workloads` (namespaced resources in `platform-demo` only, no quota or LimitRange changes). The layer Applications themselves are in `platform-admin`: anyone who may create Applications in the `argocd` namespace can name any project, so only the leaf projects carry the restrictions.

## How to ...

- **Add a workload or add-on:** one line in `envs/<env>/workloads.yaml` or `addons.yaml` (`{ app, chart, namespace }`), values in `envs/<env>/values/<app>.yaml`. *The namespace must be declared in `envs/<env>/values/cluster-bootstrap.yaml`* (with its labels): the ApplicationSets no longer create namespaces, so an undeclared one fails the sync, and CI (`inject-namespaces.py`) fails the pull request first.
- **Add a cluster-level piece:** a file in `gitops/layers/<layer>/` with a `argocd.argoproj.io/sync-wave` annotation; pick the layer by what it needs.
- **Switch a layer off:** workloads: replace the list in `envs/dev/workloads.yaml` with `[]`, or delete `apps/layer-workloads.yaml`. Namespaces are never pruned (`Prune=false,Delete=false`), so PVCs survive.
- **A second environment / cluster:** `envs/<new>/` with its own lists and values; to target another cluster, register it in Argo CD and put `cluster: <name>` on the entries (the ApplicationSets read it, default `in-cluster`), then add the destination to the `workloads` project. Application names are `<env>-<app>`.
- **Promote an image:** change `image.digest` in `envs/<env>/values/<app>.yaml` via PR.
- **Opt a namespace out of gVisor:** `sandbox: false` in `cluster-bootstrap.yaml`; one pod: annotation `platform.demo/sandbox: disabled` (`podAnnotations` in the chart's values).

## First boot: from "terraform apply finished" to "everything synced"

1. **You, once, before the first apply or at any time before step 4:** type the secrets that cannot be generated into Parameter Store (SecureString, `/platform-demo/...`): see the infra repository's `docs/secrets.md` for the table (GitHub OAuth App id and secret for Dex, a GitHub token for Backstage, a read-only Docker Hub token for Kyverno). The OAuth App's callback is `https://dex.platform-demo.click/callback`.
2. `platform-root` syncs `gitops/apps` (a few seconds): the AppProjects, then the four layer Applications.
3. **bootstrap** (about 3-10 minutes, dominated by SPIRE): namespaces and the RuntimeClass appear; the Job waits for `statefulset/spire-server` (needs its gp3 volume) and `daemonset/spire-agent`, restarts `ds/cilium` and `deploy/cilium-operator`, waits for them. Cilium re-establishes its datapath node by node.
4. **security** (about 5-10 minutes): External Secrets, then its configuration; the layer stays at this step until every ExternalSecret reports Ready, i.e. until the Parameter Store entries exist (a missing one shows as `SecretSyncedError` on the ExternalSecret: `kubectl get externalsecrets -A`). Then Kyverno, then the policies.
5. **platform and workloads** in parallel: network policy, Gateway/Dex/Backstage, the shop (database first by retries), finally Argo CD applies its own configuration: from that moment the local admin is off and sign-in is GitHub through Dex.
6. Done when `kubectl -n argocd get applications` shows everything `Synced` and `Healthy`, and https://argocd.platform-demo.click, https://backstage..., https://shop... answer.

If something is stuck: `kubectl -n argocd get applications -o wide`, then `argocd app get <name> --core` (needs no login; cluster-admin IAM is the break-glass path).

## What Terraform must provide (contract)

Namespaces `argocd`, `external-secrets` (ServiceAccount `external-secrets` with the IRSA annotation); Cilium with `authentication.mutual.spire` (server as root, gp3 PVC), WireGuard, Gateway API on the host network, Hubble; default StorageClass `gp3`; nodes with the `runsc` containerd handler; an ALB that terminates TLS and forwards HTTP to port **8080** on every node (`gateway_port`); Route 53 records for argocd, backstage, dex, hubble, shop; Argo CD helm release `argocd` (chart 10.10.0, `server.insecure=true`); `root.yaml` mirrored. **The ALB must also admit the NAT gateways' public addresses on 443**: Argo CD and Backstage fetch `https://dex.platform-demo.click` from inside the cluster, which goes out through the NAT gateway and back in through the ALB.

## Namespaces, Pod Security and gVisor

All namespaces are declared in [`envs/dev/values/cluster-bootstrap.yaml`](../envs/dev/values/cluster-bootstrap.yaml). Pods in namespaces labelled `platform.demo/sandbox=gvisor` get `runtimeClassName: gvisor` from the Kyverno mutation `pd-sandbox-gvisor` (see [policies/README.md](../policies/README.md)). Sandboxed: `platform-demo`, `backstage`, `sso`. Not sandboxed, with reasons: `argocd` (the repo-server forks helm/git constantly and Argo CD is the recovery path), `kyverno` and `external-secrets` (webhooks must run on the host network, which cannot be sandboxed), `gateway-system` (no pods), `reloader`, `kube-system`/`cilium-spire` (not ours: host network, privileged, hostPath).

Risks that only a live cluster can confirm (the user's call: debug later):

- Cilium's per-packet datapath works for gVisor pods (their traffic leaves through the veth), but Cilium's *socket-level* load balancing cannot see inside the sandbox. If Service names do not work from sandboxed pods, set `socketLB.hostNamespaceOnly=true` in the Terraform Cilium values.
- `product-catalog-db` (PostgreSQL on an EBS PVC) and `cart-redis` run sandboxed: file I/O and `fsync` through the sandbox's gofer are slower, `fsGroup` ownership is applied by the kubelet on the host before start (fine), the root filesystem is read-only plus `emptyDir` (the chart's `tmpVolume`). First fallback: annotation `platform.demo/sandbox: disabled` in `envs/dev/values/product-catalog-db.yaml` (`podAnnotations`).
- The shop's gRPC services keep long-lived HTTP/2 connections; gVisor's network stack is slower than the host's. Throughput is not a goal here; failures such as resets under load would show in Hubble.
- JVM/.NET/Node runtimes read cgroup limits through gVisor's emulated `/sys/fs/cgroup`; a service that sizes its heap wrongly shows up as OOM kills.
- Spot interruption of the node that hosts the only Kyverno replica: two replicas on two different nodes (host port 9443) mitigate this; with one node left, the second replica stays Pending and the PDB blocks a drain.

## Mutual authentication (SPIRE) and network policy

Shop services use CiliumNetworkPolicy with `authentication.mode: required` between services (`networkPolicy.cilium.authentication: required`, stated in `envs/dev/values/common.yaml`); Kyverno generates a default-deny per workload namespace. The Gateway (host network, entity `ingress`) is never asked to authenticate. Platform namespaces get plain identity-based policy from `platform-network-policies` (no mutual authentication: Dex and Backstage are reached by browsers through the Gateway).

The Job `spire-cilium-restart` is a **plain Job, not a hook**: it runs once when `cluster-bootstrap` is first synced and never again (a finished Job stays Healthy and unchanged; a hook would run after every sync). If it is deleted, self-heal recreates it and Cilium restarts once more, which is a harmless rolling restart; change `spireRestart.rerun` to run it on purpose; set `spireRestart.enabled: false` if SPIRE is ever turned off in Terraform (otherwise the layer would wait forever). Its ServiceAccount can only watch `statefulset/spire-server` and `daemonset/spire-agent` in `cilium-spire` and get/patch `daemonset/cilium` and `deployment/cilium-operator` in `kube-system`.

### After the first real deploy: verify

```bash
kubectl -n argocd get applications                      # all Synced / Healthy
kubectl -n kube-system get job spire-cilium-restart      # Complete
cilium status --wait                                     # Cilium, Operator, Hubble OK; "Encryption: Wireguard"; "Mutual authentication" enabled
kubectl -n cilium-spire get pods                         # spire-server-0 Ready, spire-agent on every node
kubectl -n cilium-spire exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server entry show | head    # entries for the Cilium identities and the pods' SPIFFE IDs
kubectl get runtimeclass gvisor                          # handler runsc
kubectl -n platform-demo get pods -o custom-columns=NAME:.metadata.name,RUNTIME:.spec.runtimeClassName     # gvisor on every pod
kubectl -n platform-demo exec deploy/frontend -- true    # refused (break-glass policy) - expected
kubectl get externalsecrets -A                           # all SecretSynced / Ready
kubectl get vpol,mpol,ivpol,gpol                         # all READY
hubble observe -n platform-demo --verdict DROPPED -f     # nothing unexpected
hubble observe -n platform-demo --type policy-verdict | grep -i auth    # "AUTH REQUIRED" turning into forwarded traffic
hubble observe -n argocd --verdict DROPPED               # Argo CD must not be dropped (egress to API server, GitHub, Dex)
hubble observe -n sso --verdict DROPPED; hubble observe -n backstage --verdict DROPPED
policies/tests/live/adversarial.sh                       # live admission suite
curl -sI https://argocd.platform-demo.click | head -3    # 200 from the ALB through the Gateway; the same for backstage, dex (/.well-known/openid-configuration), shop, hubble
```

## Gateway on EKS

`platform-gateway` declares one Gateway with an HTTP listener on 8080 (the port the ALB forwards to; Cilium binds it on every node) and HTTPRoutes for shop, argocd, hubble, backstage and dex under `platform-demo.click` (Grafana is a disabled entry: no monitoring stack on this cluster). TLS and the HTTP-to-HTTPS redirect are the ALB's. Cilium's Envoy rewrites `X-Forwarded-Proto` to the scheme of its own connection, so each route sets `X-Forwarded-Proto: https` explicitly. Argo CD runs with `server.insecure` (plain HTTP behind the ALB). Hubble UI has no login of its own: the ALB's address allow-list is its only protection.

## Operating

```bash
kubectl -n argocd get applications,applicationsets
kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite     # force a re-read of Git
argocd app diff <name> --core        # CLI in "core" mode talks to the cluster directly (set the kubectl namespace to argocd)
```

Git is polled every 2 minutes. There are no local accounts (`admin` is disabled): people sign in through Dex with GitHub, members of `platform-boutique:maintainers` administer, everyone else is read-only.

## Secrets

Git holds no secrets. They come from Parameter Store through External Secrets; the table of parameters is in the infra repository (`docs/secrets.md`), not repeated here.

## Branch testing and `targetRevision`

All Git references here say `main`. To test a branch, change them in a throw-away commit on that branch (`targetRevision:` in `bootstrap/root.yaml`, `apps/layer-*.yaml`, `layers/*/*.yaml`; `revision:` in the generators), re-apply `bootstrap/root.yaml`, and revert the commit before merging.
