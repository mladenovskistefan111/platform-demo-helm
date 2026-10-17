{{/*
CiliumNetworkPolicy equivalent of the NetworkPolicy above, with mutual authentication.

Same inputs as the Kubernetes variant:
  ingress.from / fromNamespaces / fromCIDRs / extra     egress.to / dns / monitoring / monitoringPorts / extra
Additional inputs (all optional):
  networkPolicy.cilium.authentication     "required" (default) | "disabled": SPIFFE/SPIRE mutual authentication on every
                                          rule that targets another workload (same-namespace services and the monitoring
                                          namespace). Rules for the ingress proxy, CIDRs and DNS are never authenticated.
  networkPolicy.ingress.fromEntities      Cilium entities allowed in, e.g. [ingress] for the Cilium Gateway, [host]
  networkPolicy.ingress.ports             override the ports that fromNamespaces/fromCIDRs/fromEntities may reach
  ingress.extra / egress.extra            raw CiliumNetworkPolicy rule objects

Namespaced selectors in a CiliumNetworkPolicy default to the policy's own namespace, so `from` / `to` mean "workloads
with this app.kubernetes.io/name in this namespace".
*/}}
{{- define "platform-common.ciliumnetworkpolicy" -}}
{{- if .Values.networkPolicy.enabled }}
{{- $np := .Values.networkPolicy }}
{{- $auth := (dig "cilium" "authentication" "required" ($np | default dict)) }}
{{- $ports := ($np.ingress.ports | default (list)) }}
{{- if not $ports }}
{{- range .Values.containerPorts }}
{{- $ports = append $ports (dict "port" (.containerPort | toString) "protocol" (.protocol | default "TCP")) }}
{{- end }}
{{- end }}
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: {{ include "platform-common.fullname" . }}
  labels:
    {{- include "platform-common.labels" . | nindent 4 }}
spec:
  endpointSelector:
    matchLabels:
      {{- include "platform-common.selectorLabels" . | nindent 6 }}
  ingress:
    {{- range $np.ingress.from }}
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/name: {{ . }}
      toPorts:
        - ports: {{ toJson $ports }}
      {{- if eq $auth "required" }}
      authentication:
        mode: required
      {{- end }}
    {{- end }}
    {{- range $np.ingress.fromNamespaces }}
    - fromEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": {{ . }}
      toPorts:
        - ports: {{ toJson $ports }}
    {{- end }}
    {{- with $np.ingress.fromEntities }}
    - fromEntities: {{ toJson . }}
      toPorts:
        - ports: {{ toJson $ports }}
    {{- end }}
    {{- with $np.ingress.fromCIDRs }}
    - fromCIDR: {{ toJson . }}
      toPorts:
        - ports: {{ toJson $ports }}
    {{- end }}
    {{- with $np.ingress.extra }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- if $np.egress.enabled }}
  egress:
    {{- if $np.egress.dns }}
    - toEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": kube-system
            "k8s:k8s-app": kube-dns
      toPorts:
        - ports:
            - { port: "53", protocol: ANY }
    {{- end }}
    {{- range $np.egress.to }}
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: {{ .name }}
      toPorts:
        - ports:
            - { port: {{ .port | toString | quote }}, protocol: TCP }
      {{- if eq $auth "required" }}
      authentication:
        mode: required
      {{- end }}
    {{- end }}
    {{- if $np.egress.monitoring }}
    - toEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": {{ .Values.global.monitoring.namespace }}
      toPorts:
        - ports:
            {{- range $np.egress.monitoringPorts }}
            - { port: {{ . | toString | quote }}, protocol: TCP }
            {{- end }}
      {{- if eq $auth "required" }}
      authentication:
        mode: required
      {{- end }}
    {{- end }}
    {{- with $np.egress.extra }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end -}}
