{{/*
Copyright 2026 The OKDP Authors.
Licensed under the Apache License, Version 2.0.

The instance descriptor: one ConfigMap per service instance, listed by the
console to discover instances and the connections they provide. Replaces the
KuboCD Release status, the package `usage` and the package `outputs`.
*/}}

{{/*
Hooks a service chart overrides by defining a template of the same name in its
own templates/ (a parent chart's definition wins over the library's):

  okdp.instance.url      the URL of the service UI, "" when it has none.
  okdp.instance.usage    Markdown shown by the console (former package usage).
  okdp.instance.outputs  YAML list of the connections the instance provides,
                         built with okdp.contract.<contract>.provide.

Each is called with the root context.
*/}}
{{- define "okdp.instance.url" -}}{{- end -}}
{{- define "okdp.instance.usage" -}}{{- end -}}
{{- define "okdp.instance.outputs" -}}[]{{- end -}}

{{/*
okdp.descriptor: renders the descriptor ConfigMap <release>-okdp, plus the
credentials Secret of every output declared with a `secret`.
  {{ include "okdp.descriptor" . }}
*/}}
{{- define "okdp.descriptor" -}}
{{- $ctx := . -}}{{- if and (kindIs "map" .) (hasKey . "ctx") }}{{ $ctx = .ctx }}{{ end -}}
{{- $outputsYaml := include "okdp.instance.outputs" $ctx | trim -}}
{{- $outputs := list -}}
{{- if and $outputsYaml (ne $outputsYaml "[]") -}}
  {{- $outputs = fromYamlArray $outputsYaml -}}
  {{- if and (eq (len $outputs) 1) (kindIs "string" (index $outputs 0)) (hasPrefix "error" (index $outputs 0)) -}}
    {{- fail (printf "%s: okdp.instance.outputs is not a YAML list: %s" $ctx.Chart.Name (index $outputs 0)) -}}
  {{- end -}}
{{- end -}}
{{- $published := list -}}
{{- $contracts := dict -}}
{{- $names := dict -}}
{{- range $o := $outputs -}}
  {{- $id := printf "%s/%s" $o.contract $o.name -}}
  {{- if hasKey $names $id -}}
    {{- fail (printf "%s: two %s outputs are named %q" $ctx.Chart.Name $o.contract $o.name) -}}
  {{- end -}}
  {{- $_ := set $names $id true -}}
  {{- $_ := set $contracts $o.contract true -}}
  {{- $published = append $published (omit $o "secret") -}}
{{- end -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "okdp.fullname" (dict "ctx" $ctx "suffix" "okdp") }}
  namespace: {{ $ctx.Release.Namespace }}
  labels:
    {{- include "okdp.labels" $ctx | nindent 4 }}
    {{- range $c := keys $contracts | sortAlpha }}
    okdp.io/provides-{{ $c }}: "true"
    {{- end }}
data:
  service: {{ $ctx.Chart.Name | quote }}
  version: {{ $ctx.Chart.Version | quote }}
  url: {{ include "okdp.instance.url" $ctx | trim | quote }}
  usage: |
    {{- include "okdp.instance.usage" $ctx | trim | nindent 4 }}
  outputs.yaml: |
    {{- if $published }}
    {{- toYaml $published | nindent 4 }}
    {{- else }}
    []
    {{- end }}
{{- range $o := $outputs }}
{{- with $o.secret }}
{{- if .generate }}
{{ include "okdp.generatedSecret" (dict "ctx" $ctx "name" $o.secretRef.name "keys" .generate "stringData" (.stringData | default dict) "labels" (dict (printf "okdp.io/credentials-%s" $o.contract) "true")) }}
{{- else if .stringData }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ $o.secretRef.name }}
  namespace: {{ $ctx.Release.Namespace }}
  labels:
    {{- include "okdp.labels" $ctx | nindent 4 }}
    okdp.io/credentials-{{ $o.contract }}: "true"
type: Opaque
stringData:
  {{- toYaml .stringData | nindent 2 }}
{{- else }}
{{- fail (printf "%s: output %q: secret needs stringData or generate" $ctx.Chart.Name $o.name) }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}
