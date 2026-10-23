{{- define "esc.labels" -}}
app.kubernetes.io/name: external-secrets-config
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: platform-demo
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
{{/* one `data` entry reading a String/SecureString parameter */}}
{{- define "esc.ssm" -}}
- secretKey: {{ .key }}
  remoteRef:
    key: {{ printf "%s/%s" .root.Values.ssmPrefix .path }}
{{- end }}
