# recommendation-service

Recommendation Service - random product recommendations (Python 3.12).

Built on the shared [`platform-common`](../platform-common) library chart: hardened pod spec, probes,
resources, HPA, PodDisruptionBudget, NetworkPolicy, ServiceAccount.

```bash
helm dependency update            # vendors ../platform-common into charts/
helm upgrade --install recommendation-service . -n platform-demo --create-namespace \
  --set image.tag=1.1.0
```

* Service DNS name: `recommendation-service` (port `8080`). Names are fixed to the chart name on purpose; other services are configured with them.
* All settings and their defaults are documented inline in [`values.yaml`](values.yaml); `values.schema.json` validates the important ones.
* More context for this service: its repository README and the master `README.md` of platform-demo.
