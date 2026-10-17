# ad-service

Ad Service - contextual ads over gRPC (Java 21).

Built on the shared [`platform-common`](../platform-common) library chart: hardened pod spec, probes,
resources, HPA, PodDisruptionBudget, NetworkPolicy, ServiceAccount.

```bash
helm dependency update            # vendors ../platform-common into charts/
helm upgrade --install ad-service . -n platform-demo --create-namespace \
  --set image.tag=1.0.0
```

* Service DNS name: `ad-service` (port `9555`). Names are fixed to the chart name on purpose; other services are configured with them.
* All settings and their defaults are documented inline in [`values.yaml`](values.yaml); `values.schema.json` validates the important ones.
* More context for this service: its repository README and the master `README.md` of platform-demo.
