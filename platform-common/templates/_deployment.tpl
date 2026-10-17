{{- define "platform-common.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "platform-common.fullname" . }}
  labels:
    {{- include "platform-common.labels" . | nindent 4 }}
  {{- with .Values.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- /* With an HPA the controller owns replicas; rendering it would reset scale on every upgrade. */ -}}
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  revisionHistoryLimit: {{ .Values.revisionHistoryLimit }}
  minReadySeconds: {{ .Values.minReadySeconds }}
  progressDeadlineSeconds: {{ .Values.progressDeadlineSeconds }}
  strategy:
    {{- toYaml .Values.strategy | nindent 4 }}
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
{{- end -}}
