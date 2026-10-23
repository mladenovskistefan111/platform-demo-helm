# Kyverno policies

Admission control for the cluster: what Cilium network policy and Pod Security cannot say. Kyverno **1.19.1** (chart 3.9.1) installed by Argo CD (`../gitops/layers/security/application-kyverno.yaml`, values in `../gitops/kyverno/values.yaml`); this chart (`policies/`) holds the policies, deployed by `../gitops/layers/security/application-policies.yaml` with `../clusters/main/values/policies.yaml` (the policies are cluster-wide, so they live with the cluster, not with a shop environment). On EKS the admission controller runs on the host network (port 9443): the pod network is an overlay the control plane cannot reach.

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

Scope **workload** = the three shop namespaces `platform-demo` (prod), `stage-platform-demo` and `dev-platform-demo` (strict, enforced; they are the same in every respect, see [Environments](../docs/environments.md)). Scope **platform** = `argocd`, `backstage`, `sso` (third-party stacks, the developer portal and Dex: only the generic checks, reported but never enforced unless `enforcePlatform: true`; their images - Dex, PostgreSQL, the portal - are on the platform allow-list in `values.yaml`). Namespaces are named in `values.yaml` (`scopes`), not selected by label, so a namespace cannot opt out by being relabelled. The flip side: a namespace missing from `scopes.workload` gets no policy at all, so `render-envs.py` fails the pull request when an environment's namespace is not listed (and `tests/pod-identity` documents the effect).

| Policy | Kind | Scope | Rule |
|---|---|---|---|
| `pd-pod-identity` | Validating | workload | `app.kubernetes.io/name` must be one of the 12 workload names (`identity.workloads`); the pod must run under the ServiceAccount of the same name; the label is immutable on a running pod |
| `pd-image-source` (+`-platform`) | Validating | both | every container (init, regular, ephemeral) from the scope's repository allow-list (`images.<scope>.repositories`, as `image()` normalises them: `index.docker.io/library/redis`), pinned by digest (except `digestExempt`), never `:latest`/untagged |
| `pd-verify-images` | ImageValidating | workload | images `mladenovskistefan/*` need a keyless cosign signature (classic tag format) from one of the workflows in `verifyImages.signers` (see [Who may sign](#who-may-sign-an-image)); the Helm CI gate builds its identity regexp from the same list. Admission only, background scan off |
| `pd-readonly-rootfs` (+`-platform`) | Validating | both | `readOnlyRootFilesystem: true` on every container |
| `pd-require-resources` (+`-platform`) | Validating | both | cpu+memory requests and a memory limit (no CPU limit: it only throttles) |
| `pd-require-probes` (+`-platform`) | Validating | both | readiness + liveness probe; pods of Jobs are skipped |
| `pd-service-account` | Validating | workload | not the `default` ServiceAccount; `automountServiceAccountToken: false` |
| `pd-restrict-service-types` | Validating | cluster (except `gateway-system`) | `ClusterIP` only, no `externalIPs`. The Cilium Gateway Service is a NodePort in `gateway-system` |
| `pd-restrict-route-hostnames` | Validating | cluster | HTTPRoutes must name hostnames, all under `domain` (`.platform-demo.click`) |
| `pd-protect-network-policy` | Validating | workload, platform, `gateway-system` | create/update/delete of CiliumNetworkPolicy, CiliumClusterwideNetworkPolicy, NetworkPolicy, Gateway, HTTPRoute only by Argo CD, Kyverno's generator, the namespace/garbage-collector controllers or a cluster admin (`protectedChanges`: users, groups, and `userPatterns` - regular expressions over the IAM identity EKS gives admins, because EKS access entries carry no Kubernetes group). Reads `request.userInfo`, so admission only |
| `pd-no-exec-without-break-glass` | Validating | workload | `pods/exec`, `pods/attach`, `pods/ephemeralcontainers` refused unless the pod has `platform.demo/break-glass: "true"` |
| `pd-namespace-pod-security` | Validating | cluster | workload namespaces (and any namespace labelled `platform.demo/profile: workload`) must enforce Pod Security `restricted`; platform namespaces at least `baseline` |
| `pd-default-no-api-token` | Mutating | workload | sets `automountServiceAccountToken: false` when the pod says nothing |
| `pd-default-seccomp-workload/-platform` | Mutating | both | sets `seccompProfile: RuntimeDefault` when unset |
| `pd-sandbox-gvisor` | Mutating | namespaces labelled `platform.demo/sandbox=gvisor` | sets `runtimeClassName: gvisor` (see below); `failurePolicy: Fail` |
| `pd-backstage-kubernetes-id` | Mutating | workload | copies `app.kubernetes.io/name` into `backstage.io/kubernetes-id` (the Backstage Kubernetes plugin's selector) |
| `pd-namespace-baseline` | Generating | namespaces labelled `platform.demo/profile: workload` | ResourceQuota, LimitRange (defaults for containers that declare nothing) and a `default-deny` CiliumNetworkPolicy; kept in sync, regenerated within seconds if deleted |

Mutations only touch Pods (autogen off), so Deployments stay exactly as rendered and Argo CD sees no drift.

## Modes and rolling out

`defaultAction` is `Audit` in the chart (reports and kubectl warnings, blocks nothing). `../clusters/main/values/policies.yaml` sets `Deny` for the workload scope; the platform scope stays Audit. Override one policy with `actions: { <name without pd->: Audit|Deny }`.

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

Failure policy is derived from the action: `Fail` when a policy can deny, `Ignore` while auditing, so auditing can never block admission. Webhooks skip `kube-system`, `kube-public`, `kube-node-lease`, `cilium-spire`, `cilium-secrets` and `kyverno` (`../gitops/kyverno/values.yaml`): a Kyverno outage must never stop the CNI or SPIRE.

## Exceptions

A `PolicyException` lives in the **`kyverno` namespace** (Kyverno ignores exceptions from anywhere else, `features.policyExceptions.namespace`), so nobody can exempt their own workload from inside its namespace. They are rendered from `values.yaml`:

- `verifyImages.unsigned`: images that are knowingly unsigned. Today only `product-catalog-db` (a hand-built image of the shop's in-cluster PostgreSQL, which stays a StatefulSet for now; the same entry is allow-listed by name in the Helm CI). Matched with **CEL on the pod** (label `app.kubernetes.io/name` *and* every container image starting with `mladenovskistefan/product-catalog-db@sha256:`).
- `exceptions`: anything else. Today: the Argo CD application controller has no liveness probe (upstream removed it on purpose).

Do not use `spec.images` in an exception: Kyverno before 1.19.1 ignored it (the exception then disabled verification for the *whole pod*), and matching on CEL is explicit anyway. Every exception needs a `reason`.

## Break-glass

`kubectl exec`, `attach` and `kubectl debug` into pods of the shop namespaces (`platform-demo`, `stage-platform-demo`, `dev-platform-demo`) are refused. For an incident:

```bash
kubectl -n platform-demo annotate pod <pod> platform.demo/break-glass=true
kubectl -n platform-demo exec -it <pod> -- sh
kubectl -n platform-demo annotate pod <pod> platform.demo/break-glass-          # always remove it again
```

Annotating a pod needs `update` on pods, i.e. the same trust level as exec, but it is a deliberate, visible (audit log, `kubectl get pod -o yaml`) step. Images here are mostly distroless/read-only, so also consider `kubectl debug --profile=restricted`.

## Testing

| Layer | How | What it proves |
|---|---|---|
| Unit tests | `kyverno test policies/tests` (70 cases: identity, image source, hardening, guardrails, mutation, sandbox). Render first: `helm template policies policies -f clusters/main/values/policies.yaml -s templates/<file>.yaml > policies/.rendered/<file>.yaml` | each rule passes good and rejects bad fixtures |
| Rendered environments | `.github/scripts/policy-check.sh <dir with render-envs.py output>` (CI job *Kyverno policy tests*) | every workload/add-on that Argo CD would deploy satisfies the policies that can be evaluated offline; a chart change that admission would refuse fails the PR |
| Live | `policies/tests/live/adversarial.sh` (30 cases, needs cluster-admin; dry-runs and impersonation, creates nothing) | the policies as deployed: identity theft, foreign/unpinned images, NodePort, foreign HTTPRoute, a non-admin editing CiliumNetworkPolicy, namespace Pod Security, the gVisor mutation and its opt-out, exec/debug with and without break-glass; each denial is asserted to come from the intended policy |

Offline tests cannot see the admission request, so `pd-protect-network-policy`, `pd-no-exec-without-break-glass` and signature checks are covered live only. In CI the offline evaluation skips policies with background scanning off.

## gVisor sandbox

`pd-sandbox-gvisor` (MutatingPolicy) adds `runtimeClassName: gvisor` to Pods created in namespaces labelled `platform.demo/sandbox=gvisor`. The label is set in **one** place: the namespace list in `../clusters/main/values/cluster-bootstrap.yaml` (`sandbox: true|false`); the RuntimeClass (`handler: runsc`) comes from the same chart, the `runsc` runtime from the node image (Terraform).

- **Opt a namespace out:** `sandbox: false` there (the label disappears; running pods keep their runtime until restarted).
- **Opt a pod out:** pod annotation `platform.demo/sandbox: disabled` (charts: `podAnnotations`). Pods that already name a `runtimeClassName`, use `hostNetwork`/`hostPID`/`hostIPC`, are privileged or mount a `hostPath` are skipped automatically: they cannot run in a user-space kernel.
- **Fail-closed:** `failurePolicy: Fail`, so an unavailable Kyverno refuses pods in those namespaces instead of starting them unsandboxed (Kyverno itself runs in an unlabelled namespace, so there is no deadlock). Policy objects take a few seconds to become active after they are applied; the GitOps order (security layer before platform and workloads) makes that window harmless.
- The Kyverno CLI cannot evaluate a namespace selector on a custom label offline, so `tests/sandbox` runs the policy without it (policy-check.sh strips it); the selector is part of the live suite.

## Who may sign an image

`pd-verify-images` and the `Cosign verify images` job of the Helm CI accept a signature only when the certificate identity (the workflow
that ran the signing step) matches an entry of `verifyImages.signers` in `values.yaml` - and nothing else. The old pattern accepted *any*
workflow file of *any* repository of either owner; now each form that exists is listed, with the reason it exists and when it can go:

| Signer (identity of the certificate) | Why it exists | Remove when |
|---|---|---|
| `https://github.com/platform-boutique/platform-demo-workflows/.github/workflows/service-publish.yaml@<40-hex>` | the flat publish workflow every app repository calls: all new images | never (it is the current pipeline) |
| `.../platform-boutique/platform-demo-workflows/.github/workflows/docker-promote.yaml@<40-hex>` | previous generation (v3.0 - v3.3); signed checkout-service `sha-d016e02` (dev, stage) and the portal image `0.1.1` | no digest in `envs/*/values` (or a rollback target) and no platform image was signed this way |
| `.../mladenovskistefan111/platform-demo-workflows/.github/workflows/docker-promote.yaml@<40-hex>` | the same workflow before the repository moved to the organisation (certificates keep the owner of the time): the v1.0.0 images in stage and prod | stage and prod run digests signed under `platform-boutique` and no rollback target predates the move |
| `.../mladenovskistefan111/<service>/.github/workflows/ci-main.yaml@refs/heads/feat/otlp-grpc-telemetry` (the 10 service names) | the oldest per-repository pipeline; the umbrella chart's default values (`platform-demo/values*.yaml`) still pin such digests | the umbrella chart pins digests signed by one of the entries above, or is retired |

Pinning: workflows of `platform-demo-workflows` must be called by a 40-character commit SHA (`@<40-hex>`), which is how every caller pins them;
a branch, a tag or a short SHA in the identity is refused. Per-repository `release.yaml` / `ci.yaml` signatures and any workflow of
another repository are not accepted: no image the charts reference carries them.

**How it was verified (2026-10-23, cosign v3.1.3, `--new-bundle-format=false`):** every `mladenovskistefan/*` digest in the rendered charts
(23 images: `envs/*`, the umbrella chart, the portal) was verified with the combined regexp: 22 pass, the 23rd is the unsigned
`product-catalog-db` (allow-listed). The signers of the real signatures are exactly the last three rows above; no real image is signed by
`service-publish.yaml` yet (it is new) - that identity is covered by the fixtures only. The Kyverno CLI 1.19.1 also evaluated the rendered
policy against three real signed images (one per identity form) and an unsigned one on Docker Hub: signed pass, unsigned fails; with only
the `service-publish` entry left, the three signed ones fail (so the list is an OR and the identity matters). That run needs the network and Docker Hub quota, so it is a
manual check: `kyverno apply <rendered pd-verify-images> --resource <pods with the digests>`.

**Tests (no network):** `policies/tests/signer-identities/fixtures.yaml` lists identities that must be allowed (real ones and a
`service-publish` one) and look-alikes that must be refused (foreign owner or repository, other workflow files of the workflows repository,
branch/tag/short-SHA refs, a service repo's own `publish.yaml`, `release.yaml`, ...). `.github/scripts/signer-identities.py test` renders the
real policy and checks the fixtures against its regexps and against the CI gate's combined regexp, that the template carries exactly the
list, that no cluster values file overrides it, and that every entry is covered by an allowed fixture; `policy-check.sh` runs it. The
Kyverno CLI cannot verify signatures offline, hence the identity-level test instead of a `kyverno-test.yaml`.

## Docker Hub and signature verification (read this)

`pd-verify-images` reads the image manifest and its `sha256-<digest>.sig` from Docker Hub **at every pod admission**. Anonymous pulls are limited (100 per hour per IP; on AWS all nodes share the NAT gateways' addresses), and for an enforcing policy a lookup *error* is a denial (`failurePolicy` does not change that). Therefore:

- background re-verification is off (`evaluation.background.enabled: false`);
- the policy reads Docker Hub with the read-only token in the Secret `kyverno/dockerhub-read` (`verifyImages.pullSecret`). External Secrets creates it from Parameter Store (`/platform-demo/dockerhub/username|token`, see the infra repository's `docs/secrets.md`); the GitOps order installs Kyverno only after that Secret exists. The Secret never goes into Git;
- the policy is enforced in every shop environment. If a lookup misbehaves on a first deploy, demote only this policy while debugging: `actions: { verify-images: Audit }` in `clusters/main/values/policies.yaml`.

Expected behaviour (from the unit tests and the earlier checks on the former local cluster, which no longer exists): all deployed service images verify; an image without a valid signature is denied (`image signature verification failed`); the `product-catalog-db` exception admits only that image under its own label. **Not yet verified on EKS.**

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

## Adding a shop environment

Add its namespace to `scopes.workload` in `values.yaml` and give it the same labels as the other shop namespaces in `../clusters/main/values/cluster-bootstrap.yaml`. Nothing else changes: the policies match namespaces, not environments, and the workload names (`identity.workloads`) and image repositories are the same in every environment. Add a fixture for the new namespace next to the existing ones in `tests/` (see `tests/pod-identity` for dev and stage). `render-envs.py` fails the pull request while the namespace is missing from the list.
