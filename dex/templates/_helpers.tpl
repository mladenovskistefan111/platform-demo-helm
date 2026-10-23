{{- define "dex.labels" -}}
app.kubernetes.io/name: dex
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: sso
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
{{- define "dex.image" -}}
{{ .repository }}:{{ .tag }}{{ if .digest }}@{{ .digest }}{{ end }}
{{- end }}
