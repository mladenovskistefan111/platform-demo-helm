# Kyverno policies

Admission control for the cluster: what Cilium network policy and Pod Security cannot say. Kyverno **1.19.1** (chart 3.9.1) installed by Argo CD (`../gitops/apps/application-kyverno.yaml`, values in `../gitops/kyverno/values.yaml`); this chart (`policies/`) holds the policies, deployed by `../gitops/apps/application-policies.yaml` with `../envs/<env>/values/policies.yaml`.

All policies use the CEL policy types of `policies.kyverno.io/v1` (`ValidatingPolicy`, `MutatingPolicy`, `ImageValidatingPolicy`, `GeneratingPolicy`). The old `ClusterPolicy` API is deprecated upstream and not used.

## What it protects against

| Threat | Policy |
|---|---|
| **A pod claims another service's network identity.** Cilium (network policy *and* SPIFFE mutual authentication) identifies a pod by its `app.kubernetes.io/name` label, so any pod labelled `frontend` *is* the frontend. | `pd-pod-identity` |
| A foreign, mutable or unsigned image runs in the cluster. | `pd-image-source`, `pd-verify-images` |
| A compromised workload is easy to turn into a foothold (writable filesystem, API token, no limits). | `pd-readonly-rootfs`, `pd-service-account`, `pd-require-resources`, `pd-require-probes`, mutations |
| Traffic is exposed or opened around the Gateway and the network policies. | `pd-restrict-service-types`, `pd-restrict-route-hostnames`, `pd-protect-network-policy` |
| Someone runs `kubectl exec` in a workload without it being deliberate. | `pd-no-exec-without-break-glass` |
| Pod Security is switched off for a namespace. | `pd-namespace-pod-security` |
| A new namespace has no quota, no defaults and no default-deny. | `pd-namespace-baseline` (generated) |

## Catalog

Scope **workload** = `platform-demo` (strict, enforced). Scope **platform** = `monitoring`, `argocd`, `backstage`, `sso` (third-party stacks, the developer portal and Dex: only the generic checks, reported but never enforced unless `enforcePlatform: true`; their images - Dex and the portal - are on the platform allow-list in `values.yaml`). Namespaces are named in `values.yaml` (`scopes`), not selected by label, so a namespace cannot opt out by being relabelled.

| Policy | Kind | Scope | Rule |
|---|---|---|---|
| `pd-pod-identity` | Validating | workload | `app.kubernetes.io/name` must be one of the 12 workload names (`identity.workloads`); the pod must run under the ServiceAccount of the same name; the label is immutable on a running pod |
| `pd-image-source` (+`-platform`) | Validating | both | every container (init, regular, ephemeral) from the scope's repository allow-list (`images.<scope>.repositories`, as `image()` normalises them: `index.docker.io/library/redis`), pinned by digest (except `digestExempt`), never `:latest`/untagged |
| `pd-verify-images` | ImageValidating | workload | images `mladenovskistefan/*` need a keyless cosign signature (classic tag format) from a GitHub Actions workflow of `mladenovskistefan111/*` **or `platform-boutique/*`** (images signed before the move to the organisation carry the old owner in their certificate identity, newer ones the new one; both stay valid) - the same issuer and identity regexp the Helm CI gate uses. Admission only, background scan off |
| `pd-readonly-rootfs` (+`-platform`) | Validating | both | `readOnlyRootFilesystem: true` on every container |
| `pd-require-resources` (+`-platform`) | Validating | both | cpu+memory requests and a memory limit (no CPU limit: it only throttles) |
| `pd-require-probes` (+`-platform`) | Validating | both | readiness + liveness probe; pods of Jobs are skipped |
| `pd-service-account` | Validating | workload | not the `default` ServiceAccount; `automountServiceAccountToken: false` |
| `pd-restrict-service-types` | Validating | cluster (except `gateway-system`) | `ClusterIP` only, no `externalIPs`. The Cilium Gateway Service is a NodePort in `gateway-system` |
| `pd-restrict-route-hostnames` | Validating | cluster | HTTPRoutes must name hostnames, all under `domain` (`.platform-demo.test`) |
| `pd-protect-network-policy` | Validating | workload, platform, `gateway-system` | create/update/delete of CiliumNetworkPolicy, CiliumClusterwideNetworkPolicy, NetworkPolicy, Gateway, HTTPRoute only by Argo CD, Kyverno's generator, the namespace/garbage-collector controllers or a cluster admin (`protectedChanges`). Reads `request.userInfo`, so admission only |
| `pd-no-exec-without-break-glass` | Validating | workload | `pods/exec`, `pods/attach`, `pods/ephemeralcontainers` refused unless the pod has `platform.demo/break-glass: "true"` |
| `pd-namespace-pod-security` | Validating | cluster | workload namespaces (and any namespace labelled `platform.demo/profile: workload`) must enforce Pod Security `restricted`; platform namespaces at least `baseline` |
| `pd-default-no-api-token` | Mutating | workload | sets `automountServiceAccountToken: false` when the pod says nothing |
| `pd-default-seccomp-workload/-platform` | Mutating | both | sets `seccompProfile: RuntimeDefault` when unset |
| `pd-backstage-kubernetes-id` | Mutating | workload | copies `app.kubernetes.io/name` into `backstage.io/kubernetes-id` (the Backstage Kubernetes plugin's selector) |
| `pd-namespace-baseline` | Generating | namespaces labelled `platform.demo/profile: workload` | ResourceQuota, LimitRange (defaults for containers that declare nothing) and a `default-deny` CiliumNetworkPolicy; kept in sync, regenerated within seconds if deleted |

Mutations only touch Pods (autogen off), so Deployments stay exactly as rendered and Argo CD sees no drift.

## Modes and rolling out

`defaultAction` is `Audit` in the chart (reports and kubectl warnings, blocks nothing). `envs/dev/values/policies.yaml` sets `Deny` for the workload scope; the platform scope stays Audit. Override one policy with `actions: { <name without pd->: Audit|Deny }`.

**Rolling out a new policy or scope**

1. Add it with `defaultAction: Audit` (or `actions: { new-policy: Audit }`).
2. Look at what it would block:
   ```bash
   kubectl get polr,cpolr -A                                           # PolicyReports (pass/fail counts per resource)
   kubectl get polr -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .scope as $s | .results[]? | select(.result=="fail") | "\($ns) \($s.kind)/\($s.name) \(.policy): \(.message)"'
   ```
   `kubectl apply` also prints each Audit failure as a `Warning:`.
3. Fix real findings in the charts; add a `PolicyException` only for knowing, documented deviations.
4. Flip to `Deny`, run the live suite (below), merge.

Failure policy is derived from the action: `Fail` when a policy can deny, `Ignore` while auditing, so auditing can never block admission. Webhooks skip `kube-system`, `kube-public`, `kube-node-lease`, `cilium-spire`, `cilium-secrets`, `local-path-storage` and `kyverno` (`../gitops/kyverno/values.yaml`): a Kyverno outage must never stop the CNI or SPIRE.

## Exceptions

A `PolicyException` lives in the **`kyverno` namespace** (Kyverno ignores exceptions from anywhere else, `features.policyExceptions.namespace`), so nobody can exempt their own workload from inside its namespace. They are rendered from `values.yaml`:

- `verifyImages.unsigned`: images that are knowingly unsigned. Today only `product-catalog-db` (a temporary hand-built local-testing image, replaced by RDS on AWS; the same entry is allow-listed by name in the Helm CI). Matched with **CEL on the pod** (label `app.kubernetes.io/name` *and* every container image starting with `mladenovskistefan/product-catalog-db@sha256:`).
- `exceptions`: anything else. Today: the Argo CD application controller has no liveness probe (upstream removed it on purpose).

Do not use `spec.images` in an exception: Kyverno before 1.19.1 ignored it (the exception then disabled verification for the *whole pod*), and matching on CEL is explicit anyway. Every exception needs a `reason`.

## Break-glass

`kubectl exec`, `attach` and `kubectl debug` into `platform-demo` pods are refused. For an incident:

```bash
kubectl -n platform-demo annotate pod <pod> platform.demo/break-glass=true
kubectl -n platform-demo exec -it <pod> -- sh
kubectl -n platform-demo annotate pod <pod> platform.demo/break-glass-          # always remove it again
```

Annotating a pod needs `update` on pods, i.e. the same trust level as exec, but it is a deliberate, visible (audit log, `kubectl get pod -o yaml`) step. Images here are mostly distroless/read-only, so also consider `kubectl debug --profile=restricted`.

## Testing

| Layer | How | What it proves |
|---|---|---|
| Unit tests | `kyverno test policies/tests` (49 cases: identity, image source, hardening, guardrails, mutation). Render first: `helm template policies policies -f envs/dev/values/policies.yaml -s templates/<file>.yaml > policies/.rendered/<file>.yaml` | each rule passes good and rejects bad fixtures |
| Rendered environments | `.github/scripts/policy-check.sh <dir with render-envs.py output>` (CI job *Kyverno policy tests*) | every workload/add-on that Argo CD would deploy satisfies the policies that can be evaluated offline; a chart change that admission would refuse fails the PR |
| Live | `policies/tests/live/adversarial.sh` (29 cases, needs cluster-admin; dry-runs and impersonation, creates nothing) | the policies as deployed: identity theft, foreign/unpinned images, NodePort, foreign HTTPRoute, a non-admin editing CiliumNetworkPolicy, namespace Pod Security, exec/debug with and without break-glass; each denial is asserted to come from the intended policy |

Offline tests cannot see the admission request, so `pd-protect-network-policy`, `pd-no-exec-without-break-glass` and signature checks are covered live only. In CI the offline evaluation skips policies with background scanning off.

## Docker Hub and signature verification (read this)

`pd-verify-images` reads the image manifest and its `sha256-<digest>.sig` from Docker Hub **at every pod admission**. Anonymous pulls are limited (100 per hour per IP) and a fresh `kind/up.sh` already uses most of them, so a lookup can fail with `TOOMANYREQUESTS`. For an enforcing policy a lookup *error* is a denial (`failurePolicy` does not change that), which would block rollouts. Therefore:

- background re-verification is off (`evaluation.background.enabled: false`);
- in **dev the policy only reports** (`actions: { verify-images: Audit }` in `envs/dev/values/policies.yaml`) until a read-only Docker Hub token exists;
- to enforce: create a Docker Hub access token with read-only scope, run `DOCKERHUB_USERNAME=... DOCKERHUB_TOKEN=... kind/up.sh` (or create the Secret by hand: `kubectl -n kyverno create secret docker-registry dockerhub-read --docker-server=https://index.docker.io/v1/ --docker-username=... --docker-password=...`), set `verifyImages.pullSecret: dockerhub-read` in `envs/dev/values/policies.yaml` and delete the `verify-images: Audit` override. The Secret never goes into Git.

Verified before the quota ran out (2026-10-17): all 10 deployed service images verify; an image without a valid signature is denied (`image signature verification failed`); the `product-catalog-db` exception admits only that image under its own label.

For AWS use ECR (pull-through cache) or a registry without anonymous limits; the policy only needs the image reference to point at it.

## Gotchas found building this

- **CEL: an absent map key is an error, not `false`.** `labels['x'] == 'y'` on an object without that label errors; with `failurePolicy: Fail` that turned ordinary namespace updates into denials in a first draft. Always `'x' in labels && labels['x'] == 'y'`. The unit tests cover it.
- `image()` normalises references (`mladenovskistefan/x` -> registry `index.docker.io`, repository `mladenovskistefan/x`; `redis` -> `library/redis`), but `matchImageReferences` globs match the string **as written in the pod** (`mladenovskistefan/*`, not `index.docker.io/...`).
- Server-side apply merges `validationActions` (a set) across field managers: a leftover `kubectl apply` made a policy show `[Deny, Audit, Warn]` after Argo CD changed it. Change policies through Git; if you must patch live, `kubectl apply --server-side --force-conflicts --field-manager=kubectl` the rendered chart again afterwards.
- `kubectl get vpol` shows `READY` empty for a while after creation; `status.conditionStatus.ready` is the field. "Not ready" with *missing permissions* means the reports controller lacks RBAC for that kind (`extraResources` in `../gitops/kyverno/values.yaml`).
- A `GeneratingPolicy` needs the background controller to be allowed to create what it generates (CiliumNetworkPolicy is added in the Kyverno values).
- The LimitRange generated by the baseline fills in requests/limits **before** validation, so `pd-require-resources` only bites where the baseline does not exist (platform namespaces) or the pod sets partial values.
- Kubernetes Pod Security (`restricted` label on the namespace) is still the first line for privileged/host* settings; Kyverno deliberately does not duplicate it.
- Metrics: Kyverno exposes Prometheus metrics; they are not scraped yet.

## Adding a workload

Add its name to `identity.workloads` (and a ServiceAccount of the same name; the charts do that), and, if it uses a new image repository, to `images.workload.repositories`. The Helm CI fails the PR otherwise.
