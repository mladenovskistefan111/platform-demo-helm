{{/*
Pod spec shared by Deployments and StatefulSets.
Hardening applied here regardless of values:
  - enableServiceLinks: false   (no <SVC>_SERVICE_HOST/_PORT env pollution)
  - automountServiceAccountToken follows serviceAccount.automount (default false: no API credentials in pods)
  - dnsConfig ndots 2 (override with .Values.dnsConfig): the cluster default of 5 makes a name such as
    alloy.monitoring.svc.cluster.local walk every node search domain first; one that times out upstream makes musl
    (Alpine) resolvers fail the lookup with EAI_AGAIN, so Python/Node/Java images silently lose telemetry.
*/}}
{{- define "platform-common.podSpec" -}}
serviceAccountName: {{ include "platform-common.serviceAccountName" . }}
automountServiceAccountToken: {{ .Values.serviceAccount.automount }}
enableServiceLinks: false
dnsConfig:
  {{- if .Values.dnsConfig }}
  {{- toYaml .Values.dnsConfig | nindent 2 }}
  {{- else }}
  options:
    - name: ndots
      value: "2"
  {{- end }}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.priorityClassName }}
priorityClassName: {{ . }}
{{- end }}
{{- with .Values.podSecurityContext }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
{{- with .Values.initContainers }}
initContainers:
  {{- tpl (toYaml .) $ | nindent 2 }}
{{- end }}
containers:
  - name: {{ include "platform-common.fullname" . }}
    image: {{ include "platform-common.image" . | quote }}
    imagePullPolicy: {{ .Values.image.pullPolicy }}
    {{- with .Values.command }}
    command:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.args }}
    args:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    ports:
      {{- toYaml .Values.containerPorts | nindent 6 }}
    {{- $env := include "platform-common.env" . | trim }}
    {{- if $env }}
    env:
      {{- $env | nindent 6 }}
    {{- end }}
    {{- with .Values.envFrom }}
    envFrom:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.startupProbe }}
    startupProbe:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.readinessProbe }}
    readinessProbe:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with .Values.livenessProbe }}
    livenessProbe:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- if gt (int .Values.preStopSleepSeconds) 0 }}
    lifecycle:
      preStop:
        exec:
          # Give kube-proxy / endpoint controllers time to stop routing to this pod before SIGTERM.
          command: ["sleep", {{ .Values.preStopSleepSeconds | quote }}]
    {{- end }}
    resources:
      {{- toYaml .Values.resources | nindent 6 }}
    {{- with .Values.securityContext }}
    securityContext:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- if or .Values.tmpVolume.enabled .Values.volumeMounts (and .Values.persistence .Values.persistence.enabled) }}
    volumeMounts:
      {{- if and .Values.persistence .Values.persistence.enabled }}
      - name: data
        mountPath: {{ .Values.persistence.mountPath }}
      {{- end }}
      {{- if .Values.tmpVolume.enabled }}
      - name: tmp
        mountPath: {{ .Values.tmpVolume.mountPath }}
      {{- end }}
      {{- with .Values.volumeMounts }}
      {{- toYaml . | nindent 6 }}
      {{- end }}
    {{- end }}
{{- if or .Values.tmpVolume.enabled .Values.volumes }}
volumes:
  {{- if .Values.tmpVolume.enabled }}
  - name: tmp
    emptyDir:
      sizeLimit: {{ .Values.tmpVolume.sizeLimit }}
  {{- end }}
  {{- with .Values.volumes }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- if .Values.topologySpread.enabled }}
topologySpreadConstraints:
  {{- range .Values.topologySpread.constraints }}
  - maxSkew: {{ .maxSkew }}
    topologyKey: {{ .topologyKey }}
    whenUnsatisfiable: {{ .whenUnsatisfiable }}
    labelSelector:
      matchLabels:
        {{- include "platform-common.selectorLabels" $ | nindent 8 }}
  {{- end }}
{{- end }}
{{- end -}}
