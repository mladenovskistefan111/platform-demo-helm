# product-catalog-service Helm Chart

Deploys the gRPC product catalog service (`mladenovskistefan/product-catalog-service`) into its own namespace with a **Cilium NetworkPolicy** that:

- Allows inbound gRPC traffic only from explicitly listed namespaces
- Allows metrics scraping only from within the same namespace
- Restricts egress to the `product-catalog-db` pods and DNS only

The image is referenced **by digest** (`sha256:0678cae7...`) for immutability and supply-chain traceability. The corresponding SBOM and Cosign signature tags are documented in `values.yaml`.

## Prerequisites

| Tool | Version |
|------|---------|
| Kubernetes | ≥ 1.27 (gRPC probes GA) |
| Helm | ≥ 3.10 |
| Cilium CNI | ≥ 1.13 |
| `product-catalog-db` chart | deployed in `product-catalog-db` namespace |

## Quick Start

### 1. Create the namespace

```bash
kubectl create namespace product-catalog
```

### 2. Create the credentials Secret

```bash
kubectl create secret generic product-catalog-secrets \
  --namespace product-catalog \
  --from-literal=DATABASE_URL="postgresql://catalog_user:<pw>@product-catalog-db.product-catalog-db.svc.cluster.local:5432/product_catalog"
```

### 3. Install the chart

```bash
helm install product-catalog-service ./product-catalog-service \
  --namespace product-catalog
```

### 4. Using a locally loaded image (kind / k3d)

```bash
helm install product-catalog-service ./product-catalog-service \
  --namespace product-catalog \
  --set image.pullPolicy=Never
```

## Cilium NetworkPolicy

| Direction | Rule |
|-----------|------|
| **Ingress gRPC (3550)** | Allowed from namespaces listed in `networkPolicy.allowedIngressNamespaces` |
| **Ingress metrics (9090)** | Allowed from the same namespace (Prometheus scraping) |
| **Egress DB (5432)** | Only to pods matching `networkPolicy.dbPodSelector` in `networkPolicy.dbNamespace` |
| **Egress DNS (53)** | Only to `kube-dns` in `kube-system` |
| **Everything else** | Denied |

To add a new calling namespace (e.g. an API gateway):

```bash
helm upgrade product-catalog-service ./product-catalog-service \
  --namespace product-catalog \
  --set-json 'networkPolicy.allowedIngressNamespaces=["product-catalog","api-gateway"]'
```

## Key Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `mladenovskistefan/product-catalog-service` | Image repository |
| `image.tag` | `sha256:0678cae7...` | Image digest (immutable) |
| `image.pullPolicy` | `IfNotPresent` | Set to `Never` for local images |
| `existingSecret` | `product-catalog-secrets` | Pre-existing Secret name |
| `app.grpcPort` | `3550` | gRPC container + service port |
| `app.metricsPort` | `9090` | Metrics container + service port |
| `replicaCount` | `1` | Pod replicas (use HPA for autoscaling) |
| `autoscaling.enabled` | `false` | Enable HPA |
| `networkPolicy.enabled` | `true` | Create CiliumNetworkPolicy |
| `networkPolicy.allowedIngressNamespaces` | `[product-catalog]` | Namespaces allowed to call gRPC |
| `networkPolicy.dbNamespace` | `product-catalog-db` | Namespace of the DB chart |
