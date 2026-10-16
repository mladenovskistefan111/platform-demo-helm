{{- define "platform-common.statefulset" -}}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ include "platform-common.fullname" . }}
  labels:
    {{- include "platform-common.labels" . | nindent 4 }}
spec:
  serviceName: {{ include "platform-common.fullname" . }}-headless
  replicas: {{ .Values.replicaCount }}
  revisionHistoryLimit: {{ .Values.revisionHistoryLimit }}
  minReadySeconds: {{ .Values.minReadySeconds }}
  podManagementPolicy: {{ .Values.podManagementPolicy }}
  updateStrategy:
    {{- toYaml .Values.updateStrategy | nindent 4 }}
  {{- if .Values.persistence.enabled }}
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: {{ .Values.persistence.retentionPolicy.whenDeleted }}
    whenScaled: {{ .Values.persistence.retentionPolicy.whenScaled }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "platform-common.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "platform-common.podLabels" . | nindent 8 }}
      {{- with .Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      {{- include "platform-common.podSpec" . | nindent 6 }}
  {{- if .Values.persistence.enabled }}
  volumeClaimTemplates:
    - metadata:
        name: data
        labels:
          {{- include "platform-common.selectorLabels" . | nindent 10 }}
      spec:
        accessModes:
          {{- toYaml .Values.persistence.accessModes | nindent 10 }}
        {{- with .Values.persistence.storageClassName }}
        storageClassName: {{ if eq . "-" }}""{{ else }}{{ . }}{{ end }}
        {{- end }}
        resources:
          requests:
            storage: {{ .Values.persistence.size }}
  {{- end }}
{{- end -}}
