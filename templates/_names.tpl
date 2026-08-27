{{/*
Copyright 2026 The OKDP Authors.
Licensed under the Apache License, Version 2.0.

Names, labels, hosts. Every resource name derives from .Release.Name, which is
<project>-<instance> for a project service.
*/}}

{{/*
okdp.fullname: "<release>-<suffix>", truncated to 63 characters. Without a
suffix, the release name.
  {{ include "okdp.fullname" (dict "ctx" $ "suffix" "hive-metastore") }}
*/}}
{{- define "okdp.fullname" -}}
{{- $ctx := . -}}{{- if and (kindIs "map" .) (hasKey . "ctx") }}{{ $ctx = .ctx }}{{ end -}}
{{- $suffix := "" -}}{{- if and (kindIs "map" .) (hasKey . "suffix") }}{{ $suffix = .suffix }}{{ end -}}
{{- if $suffix -}}
{{- printf "%s-%s" $ctx.Release.Name $suffix | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $ctx.Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
okdp.selectorLabels: the stable subset of okdp.labels, for selectors.
Takes `$`, or a dict {ctx, component}.
*/}}
{{- define "okdp.selectorLabels" -}}
{{- $ctx := . -}}{{- if and (kindIs "map" .) (hasKey . "ctx") }}{{ $ctx = .ctx }}{{ end -}}
app.kubernetes.io/name: {{ $ctx.Chart.Name }}
app.kubernetes.io/instance: {{ $ctx.Release.Name }}
{{- if and (kindIs "map" .) (hasKey . "component") }}
app.kubernetes.io/component: {{ .component }}
{{- end }}
{{- end -}}

{{/*
okdp.labels: labels for every resource an OKDP chart renders itself.
app.kubernetes.io/instance is the release name: the console finds workloads by
it. Takes `$`, or a dict {ctx, component}.
*/}}
{{- define "okdp.labels" -}}
{{- $ctx := . -}}{{- if and (kindIs "map" .) (hasKey . "ctx") }}{{ $ctx = .ctx }}{{ end -}}
helm.sh/chart: {{ printf "%s-%s" $ctx.Chart.Name $ctx.Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "okdp.selectorLabels" . }}
{{- with $ctx.Chart.AppVersion }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ $ctx.Release.Service }}
app.kubernetes.io/part-of: okdp
okdp.io/instance: {{ $ctx.Release.Name }}
okdp.io/service: {{ $ctx.Chart.Name }}
{{- end -}}

{{/*
okdp.ingressHost: the host a service is published on,
"<name>-<namespace>.<global.okdp.ingress.suffix>". "name" defaults to the chart
name, which keeps the KuboCD-era hosts (trino-demo.okdp.sandbox).
Takes `$`, or a dict {ctx, name}.
*/}}
{{- define "okdp.ingressHost" -}}
{{- $ctx := . -}}{{- if and (kindIs "map" .) (hasKey . "ctx") }}{{ $ctx = .ctx }}{{ end -}}
{{- $name := $ctx.Chart.Name -}}{{- if and (kindIs "map" .) (hasKey . "name") }}{{ $name = .name }}{{ end -}}
{{- include "okdp.require" (dict "ctx" $ctx "keys" (list "ingress.suffix")) -}}
{{- printf "%s-%s.%s" $name $ctx.Release.Namespace $ctx.Values.global.okdp.ingress.suffix -}}
{{- end -}}

{{/*
okdp.url: "https://" + okdp.ingressHost. Same arguments.
*/}}
{{- define "okdp.url" -}}
{{- printf "https://%s" (include "okdp.ingressHost" .) -}}
{{- end -}}

{{/*
okdp.ingressAnnotations: the annotations every OKDP ingress carries
(cert-manager issuer from global.okdp.certificateIssuers.selfSigned.name),
as a YAML map. Takes `$`.
*/}}
{{- define "okdp.ingressAnnotations" -}}
{{- $ctx := . -}}{{- if and (kindIs "map" .) (hasKey . "ctx") }}{{ $ctx = .ctx }}{{ end -}}
{{- include "okdp.require" (dict "ctx" $ctx "keys" (list "certificateIssuers.selfSigned.name")) -}}
cert-manager.io/cluster-issuer: {{ $ctx.Values.global.okdp.certificateIssuers.selfSigned.name | quote }}
{{- end -}}
