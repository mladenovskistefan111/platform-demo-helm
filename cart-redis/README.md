# cart-redis

Redis 7 datastore for the cart service.

Built on the shared [`platform-common`](../platform-common) library chart: hardened pod spec, probes,
resources, NetworkPolicy, ServiceAccount.

```bash
helm dependency update            # vendors ../platform-common into charts/
helm upgrade --install cart-redis . -n platform-demo --create-namespace \
  --set image.tag=latest
```

* Service DNS name: `cart-redis` (port `6379`). Names are fixed to the chart name on purpose; other services are configured with them.
* All settings and their defaults are documented inline in [`values.yaml`](values.yaml); `values.schema.json` validates the important ones.
* More context for this service: its repository README and the master `README.md` of platform-demo.
