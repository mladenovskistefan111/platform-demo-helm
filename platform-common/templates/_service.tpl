{{- define "platform-common.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "platform-common.fullname" . }}
  labels:
    {{- include "platform-common.labels" . | nindent 4 }}
  {{- with .Values.service.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  type: {{ .Values.service.type }}
  selector:
    {{- include "platform-common.selectorLabels" . | nindent 4 }}
  ports:
    {{- range .Values.service.ports }}
    - name: {{ .name }}
      port: {{ .port }}
      targetPort: {{ .targetPort | default .name }}
      protocol: {{ .protocol | default "TCP" }}
      {{- with .appProtocol }}
      appProtocol: {{ . }}
      {{- end }}
    {{- end }}
{{- end -}}

{{/* Headless Service that governs a StatefulSet (stable per-pod DNS). */}}
{{- define "platform-common.headlessService" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "platform-common.fullname" . }}-headless
  labels:
    {{- include "platform-common.labels" . | nindent 4 }}
spec:
  clusterIP: None
  selector:
    {{- include "platform-common.selectorLabels" . | nindent 4 }}
  ports:
    {{- range .Values.service.ports }}
    - name: {{ .name }}
      port: {{ .port }}
      targetPort: {{ .targetPort | default .name }}
    {{- end }}
{{- end -}}
