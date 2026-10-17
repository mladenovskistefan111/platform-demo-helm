{{/*
Name helpers.
Resource names are the CHART NAME (e.g. "checkout-service") on purpose, not "<release>-<chart>":
they are the in-cluster DNS names that other services are configured with
(CART_SERVICE_ADDR=cart-service:7070, ...). Override with fullnameOverride only if you also
change every caller.
*/}}
{{- define "platform-common.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "platform-common.fullname" -}}
{{- default (include "platform-common.name" .) .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "platform-common.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "platform-common.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "platform-common.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Labels used in selectors (immutable once deployed - never add to this list). */}}
{{- define "platform-common.selectorLabels" -}}
app.kubernetes.io/name: {{ include "platform-common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "platform-common.version" -}}
{{- default .Chart.AppVersion .Values.image.tag | toString -}}
{{- end -}}

{{/* Labels for every object. */}}
{{- define "platform-common.labels" -}}
helm.sh/chart: {{ include "platform-common.chart" . }}
{{ include "platform-common.selectorLabels" . }}
app.kubernetes.io/version: {{ include "platform-common.version" . | quote }}
app.kubernetes.io/component: {{ .Values.component | default "backend" }}
app.kubernetes.io/part-of: platform-demo
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Image reference: [registry/]repository[:tag][@digest].
Precedence: image.digest (immutable) > image.tag > Chart.appVersion.
image.registry falls back to global.imageRegistry (e.g. a private mirror).
*/}}
{{- define "platform-common.image" -}}
{{- $registry := default (default "" .Values.global.imageRegistry) .Values.image.registry -}}
{{- $repo := required "image.repository is required" .Values.image.repository -}}
{{- $ref := ternary $repo (printf "%s/%s" (trimSuffix "/" $registry) $repo) (empty $registry) -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $ref .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $ref (include "platform-common.version" .) -}}
{{- end -}}
{{- end -}}

{{/* Pod labels = selector labels + metadata + user labels. */}}
{{- define "platform-common.podLabels" -}}
{{ include "platform-common.selectorLabels" . }}
app.kubernetes.io/version: {{ include "platform-common.version" . | quote }}
app.kubernetes.io/component: {{ .Values.component | default "backend" }}
app.kubernetes.io/part-of: platform-demo
{{- with .Values.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Environment. Order matters: Kubernetes expands $(VAR) only from variables defined EARLIER in the list.
  1. downward API (POD_NAME, POD_NAMESPACE, NODE_NAME) + OTEL_RESOURCE_ATTRIBUTES
  2. secretEnv  (values from Secrets - e.g. DB credentials)
  3. env        (plain values; strings are passed through `tpl`, so they may use $(VAR) or {{ }})
  4. extraEnv   (raw EnvVar list)
*/}}
{{- define "platform-common.env" -}}
{{- if .Values.telemetry.k8sResourceAttributes }}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: NODE_NAME
  valueFrom:
    fieldRef:
      fieldPath: spec.nodeName
- name: OTEL_RESOURCE_ATTRIBUTES
  value: "k8s.pod.name=$(POD_NAME),k8s.namespace.name=$(POD_NAMESPACE),k8s.node.name=$(NODE_NAME)"
{{- end }}
{{- range .Values.secretEnv }}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ tpl .secretName $ }}
      key: {{ .key }}
{{- end }}
{{- range $key, $value := .Values.env }}
- name: {{ $key }}
  value: {{ tpl (toString $value) $ | quote }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end -}}
