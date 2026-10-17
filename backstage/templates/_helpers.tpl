{{- define "backstage.labels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: backstage
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}
{{- define "backstage.image" -}}
{{ .repository }}:{{ .tag }}{{ if .digest }}@{{ .digest }}{{ end }}
{{- end }}
