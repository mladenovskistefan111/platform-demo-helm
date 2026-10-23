# Environments: dev, stage, prod on one cluster

The shop runs three times on the one cluster, each copy in its own namespace. Everything that is not the shop (Argo CD, Kyverno, Dex, Backstage,
the Gateway, External Secrets, ...) exists once, in namespaces without a prefix, and is described under `clusters/main/`.

| | prod | stage | dev |
|---|---|---|---|
| Directory | `envs/prod/` | `envs/stage/` | `envs/dev/` |
| Namespace | `platform-demo` (the original name) | `stage-platform-demo` | `dev-platform-demo` |
| Argo CD Applications | `prod-<app>` | `stage-<app>` | `dev-<app>` |
| Host | `shop.platform-demo.click` | `stage.shop.platform-demo.click` | `dev.shop.platform-demo.click` |
| Database password (SSM) | `/platform-demo/product-catalog-db/postgres-password` | `/platform-demo/stage/product-catalog-db/postgres-password` | `/platform-demo/dev/product-catalog-db/postgres-password` |
| Size | one replica per service, no HPA/PDB (`envs/prod/common.yaml`, written out explicitly) | one replica (`envs/stage/common.yaml`) | one replica (`envs/dev/common.yaml`) |

```
envs/common.yaml              only what is identical in every environment (mutual authentication)
envs/<env>/common.yaml        sizing of the environment: replicas, HPA, PDB, topology spread
envs/<env>/workloads.yaml     the app list: { app, chart, namespace }   (app == chart directory name)
envs/<env>/values/<app>.yaml  what differs: image.tag + image.digest, plus app-specific settings
clusters/main/addons.yaml     the platform's own apps (Gateway, Dex, Backstage)
clusters/main/values/*.yaml   cluster-bootstrap (the namespace list), policies, external-secrets-config, platform-gateway, dex, backstage
```

Why `<env>-<app>` for every environment, prod included: an Application name has to be unique across environments, a scheme with one
exception ("prod has no prefix") is harder to read and to script, and Backstage's plugins already split `argocd/app-name` at the first dash.
Platform Applications (`kyverno`, `dex`, `policies` ...) carry no prefix because they belong to no environment.

## How an image reaches an environment

The image of an app is set in `envs/<env>/values/<app>.yaml`, nowhere else:

```yaml
image:
  tag: "1.0.0"
  digest: sha256:...   # v1.0.0
```

One file per app per environment, `<app>` = the chart directory at the repository root. Promotion is a pull request that changes `tag` and
`digest` (and the comment) of that file; each environment takes its digest from the one before it (dev -> stage -> prod, see [promote.md](promote.md)). With a digest set the pod runs `repository@digest`;
the tag only shows up as the `app.kubernetes.io/version` label. `render-envs.py` fails when a service's `tag` is missing or its digest is
not `sha256:<64 hex>`, and CI verifies the cosign signature of every digest.

`product-catalog-db` and `cart-redis` pin their (unsigned / upstream) image in the chart and have no image entry in the env files.

## Isolation

- **Network:** Kyverno generates a default-deny `CiliumNetworkPolicy` into every namespace labelled `platform.demo/profile: workload`, i.e. into
  each of the three. The allow rules each chart brings select pods of their own namespace only (`app.kubernetes.io/name` in the policy's
  namespace) plus the Gateway (`fromEntities: [ingress]`), and require SPIFFE mutual authentication. Nothing allows a pod of one environment
  to reach another one. The service names in the charts are short (`cart-service:7070`), so they resolve inside the pod's own namespace.
- **Policy:** `scopes.workload` in `policies/values.yaml` lists the three namespaces; the namespaces carry identical labels (Pod Security
  `restricted`, profile `workload`, sandbox `true`).
- **Secrets:** one ExternalSecret per namespace, each reading its own Parameter Store entry (`shop.environments` in `external-secrets-config/values.yaml`).
- **Argo CD:** the `workloads` project lists the three namespaces as destinations; the `platform` project may create the HTTPRoutes in them; `secrets` the ExternalSecrets.
- **Shared on purpose:** the node pool, the Gateway, the Kyverno cluster policies, the namespace quota (each namespace gets its own).
  `envs/common.yaml` is one file for all three environments (a change there reaches prod as well), which is why it holds nothing that may differ; sizing is per environment, so a production HA change touches `envs/prod/common.yaml` only.

## Add an app to the shop

1. Chart at the repository root (`<app>/`, thin over `platform-common`). Its name is the app name.
2. One line `{ app: <app>, chart: <app>, namespace: <env namespace> }` in `envs/<env>/workloads.yaml` of each environment that runs it.
3. `envs/<env>/values/<app>.yaml` with `image.tag` and `image.digest` (signed image) for each of those environments.
   Then add the app to the `app` options of `.github/workflows/promote.yaml` (after `all`) and `rollback.yaml`, alphabetically: the dropdowns of the browser workflows. `check-dispatch-apps.py` fails the pull request with the exact line to paste.
4. `policies/values.yaml`: the name in `identity.workloads`, and a new image repository in `images.workload.repositories`. The Kyverno check in CI fails otherwise.
5. The catalog entry in the app's own repository (`argocd/app-name: <env>-<app>`, see the portal documentation).

The namespaces already exist; nothing else is needed. A platform add-on is one line in `clusters/main/addons.yaml` and, if it has a namespace of its own, one
entry in `clusters/main/values/cluster-bootstrap.yaml`.

## Add an environment (say `qa`)

1. `envs/qa/workloads.yaml` (copy of another environment, namespace `qa-platform-demo`), `envs/qa/common.yaml` (sizing) and `envs/qa/values/` (copy; set the digests you want).
2. The namespace in `clusters/main/values/cluster-bootstrap.yaml` with the same labels as the other shop namespaces.
3. `policies/values.yaml`: the namespace in `scopes.workload`.
4. `external-secrets-config/values.yaml`: the namespace in `allowedNamespaces` and an entry in `shop.environments` with its own `passwordPath`
   (`qa/product-catalog-db/postgres-password`); create that SecureString by hand (`docs/secrets.md`).
5. `gitops/apps/appproject-{workloads,platform,secrets}.yaml`: the namespace as a destination.
6. `platform-gateway/values.yaml`: a route (`shop-qa`, host `qa.shop`) in the new namespace.
7. Terraform (infra repository): the DNS name `qa.shop` and a certificate name for it (the wildcard `*.shop.platform-demo.click` covers all of them).

`.github/scripts/render-envs.py` checks 2, 3, 4, 5 and 6 and the uniqueness of namespaces, hosts, parameter paths and Application names, so the
pull request fails instead of the first sync. Step 7 and the SecureString cannot be checked from this repository.

## Terraform's part (not in this repository)

Hosts `dev.shop` and `stage.shop` under the domain must point at the ALB (the `hostnames` list of stack `platform`: `"dev.shop"`, `"stage.shop"`),
and the ACM certificate needs a name that covers them: `*.platform-demo.click` does not (a wildcard stops at one label), so add
`*.shop.platform-demo.click` (or the two names) to `subject_alternative_names` of `modules/certificate`. The ALB's HTTPS listener forwards every
host to the Gateway, which routes by host name, so no listener rule is needed.
