{{/* Egress to CoreDNS. */}}
{{- define "pnp.dns" -}}
- toEndpoints:
    - matchLabels:
        "k8s:io.kubernetes.pod.namespace": kube-system
        "k8s:k8s-app": kube-dns
  toPorts:
    - ports:
        - { port: "53", protocol: ANY }
{{- end -}}

{{/* Egress to the Kubernetes API server (EKS: ENIs in the VPC, recognised by Cilium as the kube-apiserver entity). */}}
{{- define "pnp.apiserver" -}}
- toEntities: [kube-apiserver]
{{- end -}}

{{/* Egress to the internet over TLS (GitHub, Helm repositories, the public Dex/Argo CD URLs through the NAT gateways and the ALB). */}}
{{- define "pnp.https" -}}
- toEntities: [world]
  toPorts:
    - ports:
        - { port: "443", protocol: TCP }
{{- end -}}

{{- define "pnp.labels" -}}
app.kubernetes.io/part-of: platform-demo
app.kubernetes.io/managed-by: {{ .Release.Service }}
platform.demo/component: network-policy
{{- end -}}
