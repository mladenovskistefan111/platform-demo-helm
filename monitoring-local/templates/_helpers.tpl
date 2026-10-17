{{- define "ml.image" -}}
{{ .repository }}:{{ .tag }}{{ if .digest }}@{{ .digest }}{{ end }}
{{- end }}

{{- define "ml.labels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: monitoring-local
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
{{- end }}

{{/* Pod/container security shared by every component. */}}
{{- define "ml.podSecurity" -}}
runAsNonRoot: true
runAsUser: {{ .uid }}
runAsGroup: {{ .uid }}
fsGroup: {{ .uid }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "ml.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true   # writable paths are explicit: the data emptyDirs and /tmp below (Kyverno: pd-readonly-rootfs)
capabilities:
  drop: [ALL]
{{- end }}

{{/*
Generic single-replica workload + Service.
params: root, name, uid, image, args, env (list), ports ([{name, port}]), probe {path, port},
        resources, configMap (name of ConfigMap mounted at /etc/<name>), dataPaths (emptyDir mounts),
        extraVolumes / extraMounts (pre-rendered YAML lists), serviceAccount (bool)
*/}}
{{- define "ml.workload" -}}
{{- $p := . -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $p.name }}
  namespace: {{ $p.root.Release.Namespace }}
  labels: {{- include "ml.labels" (dict "name" $p.name "root" $p.root) | nindent 4 }}
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ $p.name }}
      app.kubernetes.io/instance: {{ $p.root.Release.Name }}
  template:
    metadata:
      labels: {{- include "ml.labels" (dict "name" $p.name "root" $p.root) | nindent 8 }}
      annotations:
        checksum/config: {{ $p.checksum | default "" | quote }}
    spec:
      {{- if $p.serviceAccount }}
      serviceAccountName: {{ $p.name }}
      {{- else }}
      automountServiceAccountToken: false
      {{- end }}
      securityContext: {{- include "ml.podSecurity" $p | nindent 8 }}
      containers:
        - name: {{ $p.name }}
          image: {{ $p.image }}
          imagePullPolicy: {{ $p.root.Values.images.pullPolicy }}
          {{- with $p.workingDir }}
          workingDir: {{ . }}
          {{- end }}
          {{- with $p.args }}
          args: {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $p.env }}
          env: {{- toYaml . | nindent 12 }}
          {{- end }}
          ports:
            {{- range $p.ports }}
            - { name: {{ .name }}, containerPort: {{ .port }} }
            {{- end }}
          readinessProbe:
            httpGet: { path: {{ $p.probe.path }}, port: {{ $p.probe.port }} }
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet: { path: {{ $p.probe.path }}, port: {{ $p.probe.port }} }
            initialDelaySeconds: 60
            periodSeconds: 20
            failureThreshold: 6
          resources: {{- toYaml $p.resources | nindent 12 }}
          securityContext: {{- include "ml.containerSecurity" $p | nindent 12 }}
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
            {{- if $p.configMap }}
            - { name: config, mountPath: /etc/{{ $p.name }} }
            {{- end }}
            {{- range $i, $d := $p.dataPaths }}
            - { name: data-{{ $i }}, mountPath: {{ $d }} }
            {{- end }}
            {{- with $p.extraMounts }}
            {{- . | nindent 12 }}
            {{- end }}
      volumes:
        - { name: tmp, emptyDir: { sizeLimit: 64Mi } }
        {{- if $p.configMap }}
        - name: config
          configMap: { name: {{ $p.configMap }} }
        {{- end }}
        {{- range $i, $d := $p.dataPaths }}
        - { name: data-{{ $i }}, emptyDir: {} }
        {{- end }}
        {{- with $p.extraVolumes }}
        {{- . | nindent 8 }}
        {{- end }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $p.name }}
  namespace: {{ $p.root.Release.Namespace }}
  labels: {{- include "ml.labels" (dict "name" $p.name "root" $p.root) | nindent 4 }}
spec:
  selector:
    app.kubernetes.io/name: {{ $p.name }}
    app.kubernetes.io/instance: {{ $p.root.Release.Name }}
  ports:
    {{- range $p.ports }}
    - { name: {{ .name }}, port: {{ .port }}, targetPort: {{ .name }}{{ if .appProtocol }}, appProtocol: {{ .appProtocol }}{{ end }} }
    {{- end }}
{{- end }}
