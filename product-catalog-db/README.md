# product-catalog-db Helm Chart

Deploys a PostgreSQL database (image: `mladenovskistefan/product-catalog-db`) into its own namespace with a **Cilium NetworkPolicy** that allows inbound connections _only_ from `product-catalog-service`.

## Prerequisites

| Tool | Version |
|------|---------|
| Kubernetes | ≥ 1.25 |
| Helm | ≥ 3.10 |
| Cilium CNI | ≥ 1.13 |

## Quick Start

### 1. Create the namespace

```bash
kubectl create namespace product-catalog-db
```

### 2. Create the credentials Secret

Never store passwords in `values.yaml`.  Create the Secret once, out of band:

```bash
kubectl create secret generic postgres-credentials \
  --namespace product-catalog-db \
  --from-literal=POSTGRES_USER=catalog_user \
  --from-literal=POSTGRES_PASSWORD=<your-password> \
  --from-literal=POSTGRES_DB=product_catalog
```

### 3. Install the chart

```bash
helm install product-catalog-db ./product-catalog-db \
  --namespace product-catalog-db
```

### 4. Using a locally loaded image (kind / k3d)

```bash
# Load the image into your local cluster first, then:
helm install product-catalog-db ./product-catalog-db \
  --namespace product-catalog-db \
  --set image.pullPolicy=Never
```

## Cilium NetworkPolicy

The policy (in `templates/cilium-network-policy.yaml`) enforces:

| Direction | Rule |
|-----------|------|
| **Ingress** | Only pods with label `app: product-catalog-service` in namespace `product-catalog` may reach TCP port 5432 |
| **Egress** | Only DNS (UDP+TCP 53 to `kube-dns`) is allowed; all other outbound traffic is denied |

To point at a different calling namespace or pod selector, override:

```bash
helm install product-catalog-db ./product-catalog-db \
  --namespace product-catalog-db \
  --set networkPolicy.clientNamespace=my-namespace \
  --set networkPolicy.clientPodSelector.app=my-service
```

## Values Reference

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `mladenovskistefan/product-catalog-db` | Image repository |
| `image.tag` | `latest` | Image tag |
| `image.pullPolicy` | `IfNotPresent` | Pull policy (`Never` for local images) |
| `existingSecret` | `postgres-credentials` | Name of the pre-existing credentials Secret |
| `postgres.port` | `5432` | Container port and Service port |
| `postgres.user` | `catalog_user` | Used by readiness/liveness probes only |
| `postgres.database` | `product_catalog` | Used by readiness/liveness probes only |
| `persistence.enabled` | `true` | Mount a PVC for data |
| `persistence.size` | `1Gi` | PVC size |
| `persistence.storageClassName` | `""` | Leave empty for cluster default |
| `networkPolicy.enabled` | `true` | Create the CiliumNetworkPolicy |
| `networkPolicy.clientNamespace` | `product-catalog` | Namespace of the calling service |
| `networkPolicy.clientPodSelector` | `{app: product-catalog-service}` | Label selector for allowed pods |
| `resources` | see values.yaml | CPU / memory requests and limits |
