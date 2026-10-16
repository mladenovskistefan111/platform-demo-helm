{{/*
NetworkPolicy: default-deny for the selected pods, then allow exactly what the service needs.

ingress.from           service names (same namespace) allowed to connect, matched on app.kubernetes.io/name
ingress.fromNamespaces namespaces (by kubernetes.io/metadata.name) allowed to connect, e.g. the ingress controller
egress.to              [{name, port}] same-namespace services this pod may call
egress.dns             allow DNS to kube-dns
egress.monitoring      allow OTLP/Pyroscope traffic to global.monitoring.namespace
egress.extra / ingress.extra  raw NetworkPolicy rules
*/}}
{{- define "platform-common.networkpolicy" -}}
{{- if .Values.networkPolicy.enabled }}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "platform-common.fullname" . }}
  labels:
    {{- include "platform-common.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "platform-common.selectorLabels" . | nindent 6 }}
  policyTypes:
    - Ingress
    {{- if .Values.networkPolicy.egress.enabled }}
    - Egress
    {{- end }}
  ingress:
    {{- if or .Values.networkPolicy.ingress.from .Values.networkPolicy.ingress.fromNamespaces .Values.networkPolicy.ingress.fromCIDRs }}
    - from:
        {{- range .Values.networkPolicy.ingress.from }}
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: {{ . }}
        {{- end }}
        {{- range .Values.networkPolicy.ingress.fromNamespaces }}
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ . }}
        {{- end }}
        {{- range .Values.networkPolicy.ingress.fromCIDRs }}
        - ipBlock:
            cidr: {{ . }}
        {{- end }}
      ports:
        {{- range .Values.containerPorts }}
        - port: {{ .containerPort }}
          protocol: {{ .protocol | default "TCP" }}
        {{- end }}
    {{- end }}
    {{- with .Values.networkPolicy.ingress.extra }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- if .Values.networkPolicy.egress.enabled }}
  egress:
    {{- if .Values.networkPolicy.egress.dns }}
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    {{- end }}
    {{- range .Values.networkPolicy.egress.to }}
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: {{ .name }}
      ports:
        - port: {{ .port }}
          protocol: TCP
    {{- end }}
    {{- if .Values.networkPolicy.egress.monitoring }}
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ .Values.global.monitoring.namespace }}
      ports:
        {{- range .Values.networkPolicy.egress.monitoringPorts }}
        - port: {{ . }}
          protocol: TCP
        {{- end }}
    {{- end }}
    {{- with .Values.networkPolicy.egress.extra }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end -}}
