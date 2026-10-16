{{- define "platform-common.pdb" -}}
{{- if .Values.podDisruptionBudget.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "platform-common.fullname" . }}
  labels:
    {{- include "platform-common.labels" . | nindent 4 }}
spec:
  selector:
    matchLabels:
      {{- include "platform-common.selectorLabels" . | nindent 6 }}
  {{- if .Values.podDisruptionBudget.minAvailable }}
  minAvailable: {{ .Values.podDisruptionBudget.minAvailable }}
  {{- else }}
  maxUnavailable: {{ .Values.podDisruptionBudget.maxUnavailable | default 1 }}
  {{- end }}
  {{- if semverCompare ">=1.27.0-0" .Capabilities.KubeVersion.Version }}
  # Pods that never became Ready must not block node drains.
  unhealthyPodEvictionPolicy: AlwaysAllow
  {{- end }}
{{- end }}
{{- end -}}
