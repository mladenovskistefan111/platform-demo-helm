{{/* Shared container settings for the one-off Job: read-only root, no capabilities, HOME on a scratch volume (kubectl's discovery cache). */}}
{{- define "cluster-bootstrap.container" -}}
env:
  - { name: HOME, value: /tmp }
resources: {{- toYaml .Values.spireRestart.resources | nindent 2 }}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: [ALL] }
volumeMounts:
  - { name: tmp, mountPath: /tmp }
{{- end -}}
