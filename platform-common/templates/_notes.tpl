{{- define "platform-common.notes" -}}
{{ include "platform-common.fullname" . }} {{ include "platform-common.version" . }} installed as release "{{ .Release.Name }}" in namespace "{{ .Release.Namespace }}".

In-cluster address (used by other platform-demo services):
{{- range .Values.service.ports }}
  {{ include "platform-common.fullname" $ }}.{{ $.Release.Namespace }}.svc.cluster.local:{{ .port }}   ({{ .name }})
{{- end }}

Check rollout:
  kubectl -n {{ .Release.Namespace }} rollout status {{ if and .Values.persistence .Values.persistence.enabled }}statefulset{{ else }}deploy{{ end }}/{{ include "platform-common.fullname" . }}
{{- if .Values.ingress.enabled }}

Ingress hosts:
{{- range .Values.ingress.hosts }}
  https://{{ .host }}
{{- end }}
{{- end }}
{{- if not (and .Values.persistence .Values.persistence.enabled) }}

Note: gRPC keeps long-lived HTTP/2 connections, so a ClusterIP Service balances per connection, not per
request. Extra replicas receive new connections (e.g. after restarts), not live traffic shifts.
{{- end }}
{{- end -}}
