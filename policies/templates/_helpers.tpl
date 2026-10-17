{{/* Labels on every policy object. */}}
{{- define "pd.labels" -}}
app.kubernetes.io/part-of: platform-demo
app.kubernetes.io/managed-by: {{ .Release.Service }}
platform.demo/component: policy
{{- end -}}

{{/* Action for policy <key> in <scope>: args = (root key scope). Audit also warns the caller, Deny also reports. */}}
{{- define "pd.action" -}}
{{- $root := index . 0 -}}{{- $key := index . 1 -}}{{- $scope := index . 2 -}}
{{- $a := default $root.Values.defaultAction (get $root.Values.actions $key) -}}
{{- if and (ne $scope "workload") (not $root.Values.enforcePlatform) -}}{{- $a = "Audit" -}}{{- end -}}
{{- $a -}}
{{- end -}}

{{/* validationActions + failurePolicy: Fail only when the policy can actually deny, so auditing never blocks anything. */}}
{{- define "pd.actionSpec" -}}
{{- $a := include "pd.action" . -}}
{{- if eq $a "Deny" -}}
validationActions: [Deny, Audit]
failurePolicy: Fail
{{- else -}}
validationActions: [Audit, Warn]
failurePolicy: Ignore
{{- end -}}
{{- end -}}

{{/* namespaceSelector for a scope: args = (root scope). */}}
{{- define "pd.nsSelector" -}}
{{- $root := index . 0 -}}{{- $scope := index . 1 -}}
namespaceSelector:
  matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: In
      values: {{ toJson (get $root.Values.scopes $scope) }}
{{- end -}}

{{- define "pd.podRules" -}}
- apiGroups: [""]
  apiVersions: ["v1"]
  operations: ["CREATE", "UPDATE"]
  resources: ["pods"]
{{- end -}}

{{/*
A ValidatingPolicy rendered once per scope. dict keys:
  root, name, title, description, scopes (list), rules (YAML list), variables (YAML list, optional), validations (YAML list),
  matchConditions (YAML list, optional), clusterWide (bool: no namespaceSelector), nsSelector (raw YAML, overrides), controllers (list, restricts autogen to these pod controllers), background (false: admission only; for rules that use request.userInfo or subresources)
The workload policy is called pd-<name>, other scopes pd-<name>-<scope>.
*/}}
{{- define "pd.vpol" -}}
{{- $p := . -}}
{{- range $scope := $p.scopes }}
---
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: pd-{{ $p.name }}{{ if ne $scope "workload" }}-{{ $scope }}{{ end }}
  labels:
    {{- include "pd.labels" $p.root | nindent 4 }}
  annotations:
    policies.kyverno.io/title: {{ $p.title | quote }}
    policies.kyverno.io/description: {{ $p.description | quote }}
spec:
  {{- include "pd.actionSpec" (list $p.root $p.name $scope) | nindent 2 }}
  matchConstraints:
    {{- if $p.nsSelector }}
    {{- $p.nsSelector | nindent 4 }}
    {{- else if not $p.clusterWide }}
    {{- include "pd.nsSelector" (list $p.root $scope) | nindent 4 }}
    {{- end }}
    resourceRules:
      {{- $p.rules | nindent 6 }}
  {{- with $p.controllers }}
  autogen:
    podControllers:
      controllers: {{ toJson . }}
  {{- end }}
  {{- if eq (toString $p.background) "false" }}
  evaluation:
    background: { enabled: false }
  {{- end }}
  {{- with $p.matchConditions }}
  matchConditions:
    {{- . | nindent 4 }}
  {{- end }}
  {{- with $p.variables }}
  variables:
    {{- . | nindent 4 }}
  {{- end }}
  validations:
    {{- $p.validations | nindent 4 }}
{{- end }}
{{- end -}}
