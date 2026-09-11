{{/*
Copyright 2026 The OKDP Authors.
Licensed under the Apache License, Version 2.0.

Rendering of vendored upstream charts with computed values.

Why: a Helm subchart only ever sees static values. A former KuboCD module
rendered its values from a template (Context, Parameters, resolved
connections), which Helm cannot do for a dependency. So the upstream chart is
vendored (unpacked under vendor/<name>/ of the wrapper chart, see
scripts/vendor-charts.sh) and rendered from the wrapper's own templates with
values the wrapper computes: the KuboCD two-stage render (values template, then
chart), inside a single `helm template`.
*/}}

{{/*
okdp.vendor.render: renders the chart unpacked under vendor/<chart>/ with the
given values, as a multi-document YAML stream.

  {{- $values := include "mychart.trino.values" . | fromYaml }}
  {{ include "okdp.vendor.render" (dict "ctx" $ "chart" "trino" "values" $values) }}

Arguments:
  ctx     the root context ($).
  chart   the directory name under vendor/.
  values  the values, merged over vendor/<chart>/values.yaml (maps merge, lists
          and scalars replace; a null sets the key to null where Helm would
          delete it, which reads the same in templates except for hasKey).
          .Values.global of the wrapper is passed down as global.

The upstream templates see .Values, .Release (the wrapper's release, so names
and app.kubernetes.io/instance derive from <project>-<instance>), .Chart
(from vendor/<chart>/Chart.yaml), .Capabilities, .Template.BasePath and
.Files, where literal `.Files.Get "x"` / `.Files.Glob "x"` are rewritten to the
vendored directory. Partials (_*.tpl) of the chart and of its library
subcharts are loaded; templates/tests/ and NOTES.txt are skipped. A vendored
chart that bundles an application subchart is refused: vendor and render that
subchart on its own. Hooks keep their annotations, so they behave as in the
upstream chart. Objects and pod templates missing the label
app.kubernetes.io/instance get it (pass "instanceLabel" false to opt out).
*/}}
{{- define "okdp.vendor.render" -}}
{{- $ctx := .ctx -}}
{{- $name := required "okdp.vendor.render: chart is required" .chart -}}
{{- $dir := printf "vendor/%s" $name -}}
{{- $chartYaml := $ctx.Files.Get (printf "%s/Chart.yaml" $dir) -}}
{{- if not $chartYaml -}}
  {{- fail (printf "%s: %s/Chart.yaml not found: run scripts/vendor-charts.sh %s" $ctx.Chart.Name $dir $ctx.Chart.Name) -}}
{{- end -}}
{{- $meta := fromYaml $chartYaml -}}
{{- $defaults := fromYaml ($ctx.Files.Get (printf "%s/values.yaml" $dir)) | default dict -}}
{{- if hasKey $defaults "Error" -}}
  {{- fail (printf "%s: %s/values.yaml: %s" $ctx.Chart.Name $dir $defaults.Error) -}}
{{- end -}}
{{- $values := mergeOverwrite (deepCopy $defaults) (deepCopy (.values | default dict)) -}}
{{- $global := mergeOverwrite (deepCopy ($defaults.global | default dict)) (deepCopy ($ctx.Values.global | default dict)) ((.values | default dict).global | default dict) -}}
{{- $_ := set $values "global" $global -}}
{{- $chart := dict
      "Name" (toString $meta.name)
      "Version" (toString $meta.version)
      "AppVersion" (toString ($meta.appVersion | default ""))
      "Description" ($meta.description | default "")
      "Type" ($meta.type | default "application")
      "APIVersion" ($meta.apiVersion | default "v2")
      "KubeVersion" ($meta.kubeVersion | default "")
      "Home" ($meta.home | default "")
      "Icon" ($meta.icon | default "")
      "Keywords" ($meta.keywords | default list)
      "Sources" ($meta.sources | default list)
      "Annotations" ($meta.annotations | default dict)
      "IsRoot" false -}}
{{- $root := dict
      "Values" $values
      "Release" $ctx.Release
      "Chart" $chart
      "Capabilities" $ctx.Capabilities
      "Files" $ctx.Files
      "Template" (dict "Name" (printf "%s/templates" $dir) "BasePath" (printf "%s/templates" $dir)) -}}
{{- range $sub, $_ := $ctx.Files.Glob (printf "%s/charts/*/Chart.yaml" $dir) -}}
  {{- $subMeta := fromYaml ($ctx.Files.Get $sub) -}}
  {{- if ne ($subMeta.type | default "application") "library" -}}
    {{- fail (printf "%s: vendored chart %s bundles the application subchart %s, which okdp.vendor.render does not render: vendor it as a chart of its own" $ctx.Chart.Name $name (dir $sub)) -}}
  {{- end -}}
{{- end -}}
{{- $partials := list -}}
{{- range $path, $_ := $ctx.Files.Glob (printf "%s/charts/*/templates/_*" $dir) -}}
  {{- $partials = append $partials $path -}}
{{- end -}}
{{- $manifests := list -}}
{{- range $path, $_ := $ctx.Files.Glob (printf "%s/templates/**" $dir) -}}
  {{- $base := base $path -}}
  {{- if contains "/templates/tests/" $path -}}
  {{- else if eq $base "NOTES.txt" -}}
  {{- else if hasPrefix "_" $base -}}
    {{- $partials = append $partials $path -}}
  {{- else -}}
    {{- $manifests = append $manifests $path -}}
  {{- end -}}
{{- end -}}
{{- /*
One template text, like Helm's own render of a chart: the partials, then every
manifest at top level (so a `define` inside a manifest works and is visible to
the others), each introduced by a separator printed by an action (so the
whitespace trimming of the upstream `{{-`/`-}}` cannot eat it). Manifests
without a `define` are also registered under their path, for
`include (print $.Template.BasePath "/x.yaml") .` (checksum annotations).
*/ -}}
{{- $bundle := "" -}}
{{- range $path := $partials -}}
  {{- $bundle = print $bundle (include "okdp.vendor.files" (dict "content" ($ctx.Files.Get $path) "dir" $dir)) "\n" -}}
{{- end -}}
{{- range $path := $manifests -}}
  {{- $content := include "okdp.vendor.files" (dict "content" ($ctx.Files.Get $path) "dir" $dir) -}}
  {{- if not (regexMatch "{{-?\\s*define\\s" $content) -}}
    {{- $bundle = print $bundle "{{ define " (quote $path) " }}" $content "{{ end }}\n" -}}
  {{- end -}}
{{- end -}}
{{- range $path := $manifests -}}
  {{- $bundle = print $bundle "{{ " (quote (printf "\n---\n# Source: %s\n" $path)) " }}" (include "okdp.vendor.files" (dict "content" ($ctx.Files.Get $path) "dir" $dir)) -}}
{{- end -}}
{{- $rendered := tpl $bundle $root -}}
{{- if eq (toString (.instanceLabel | default "true")) "false" -}}
{{- $rendered -}}
{{- else -}}
{{- include "okdp.vendor.instanceLabel" (dict "rendered" $rendered "release" $ctx.Release.Name) -}}
{{- end -}}
{{- end -}}

{{/*
okdp.vendor.instanceLabel: internal. Adds app.kubernetes.io/instance: <release>
where an upstream chart leaves it out: on every object, and on the pod
template of workloads (the console finds pods by it). Selectors are left
alone. Documents that need no change are passed through untouched; the others
are re-serialised (same content, keys sorted, comments dropped).
*/}}
{{- define "okdp.vendor.instanceLabel" -}}
{{- $key := "app.kubernetes.io/instance" -}}
{{- $release := .release -}}
{{- range $doc := regexSplit "(?m)^---[ \\t]*$" .rendered -1 -}}
  {{- $obj := fromYaml $doc -}}
  {{- if or (not $obj) (hasKey $obj "Error") (not (kindIs "map" $obj.metadata)) -}}
{{ print "\n---" $doc }}
  {{- else -}}
    {{- $changed := false -}}
    {{- $meta := $obj.metadata -}}
    {{- $labels := $meta.labels | default dict -}}
    {{- if not (hasKey $labels $key) -}}
      {{- $_ := set $labels $key $release -}}{{- $_ := set $meta "labels" $labels -}}{{- $changed = true -}}
    {{- end -}}
    {{- $tpl := dict -}}
    {{- if has (toString $obj.kind) (list "Deployment" "StatefulSet" "DaemonSet" "ReplicaSet" "Job") -}}
      {{- $tpl = (($obj.spec | default dict).template) | default dict -}}
    {{- else if eq (toString $obj.kind) "CronJob" -}}
      {{- $tpl = (((($obj.spec | default dict).jobTemplate | default dict).spec | default dict).template) | default dict -}}
    {{- end -}}
    {{- if $tpl -}}
      {{- $podMeta := $tpl.metadata | default dict -}}
      {{- $podLabels := $podMeta.labels | default dict -}}
      {{- if not (hasKey $podLabels $key) -}}
        {{- $_ := set $podLabels $key $release -}}{{- $_ := set $podMeta "labels" $podLabels -}}{{- $_ := set $tpl "metadata" $podMeta -}}{{- $changed = true -}}
      {{- end -}}
    {{- end -}}
    {{- if $changed }}
---
{{ regexFind "# Source: [^\\n]*" $doc }}
{{ toYaml $obj }}
    {{- else -}}
{{ print "\n---" $doc }}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
okdp.vendor.oidcDcr: renders the chart unpacked under vendor/oidc-dcr/ (the
Job that registers an OAuth client by dynamic client registration and writes
it to a Secret, clientProvisioning: dcr) with names of its own.

  {{ include "okdp.vendor.oidcDcr" (dict "ctx" $ "values" $v) }}
  {{ include "okdp.vendor.oidcDcr" (dict "ctx" $ "values" $v "name" (include "okdp.fullname" (dict "ctx" $ "suffix" "console-oidc-dcr"))) }}

Arguments:
  ctx     the root context ($).
  values  the oidc-dcr values, as for okdp.vendor.render.
  name    default <release>-oidc-dcr: the Job, its ConfigMap, ServiceAccount,
          Role and RoleBinding, and the headless Service <name>-headless.

oidc-dcr 0.3.3 names its Job, ConfigMap, RoleBinding and headless Service
"dcr"/"dcr-headless" whatever the release: two DCR clients of one namespace
(two releases, or two clients of one release) would share them, the second
replacing the first. They are renamed here, with the references to them (the
Job's ConfigMap volume, the Service selector job-name); the ServiceAccount and
Role are named through the values (security.service_account, security.role),
which this helper sets. The renamed documents are re-serialised (same content,
keys sorted, comments dropped). Fails when an expected object is missing: the
upstream chart changed.
*/}}
{{- define "okdp.vendor.oidcDcr" -}}
{{- $ctx := .ctx -}}
{{- $name := .name | default (include "okdp.fullname" (dict "ctx" $ctx "suffix" "oidc-dcr")) -}}
{{- $headless := printf "%s-headless" $name | trunc 63 | trimSuffix "-" -}}
{{- $values := deepCopy (.values | default dict) -}}
{{- $_ := set $values "security" (merge (dict "service_account" $name "role" $name) ($values.security | default dict)) -}}
{{- $_ := set $values.security "service_account" $name -}}
{{- $_ := set $values.security "role" $name -}}
{{- $rendered := include "okdp.vendor.render" (dict "ctx" $ctx "chart" "oidc-dcr" "values" $values) -}}
{{- $renames := dict "ConfigMap/dcr" $name "Job/dcr" $name "RoleBinding/dcr" $name "Service/dcr-headless" $headless -}}
{{- $seen := dict -}}
{{- $out := "" -}}
{{- range $doc := regexSplit "(?m)^---[ \\t]*$" $rendered -1 -}}
  {{- $obj := fromYaml $doc -}}
  {{- $key := "" -}}
  {{- if and $obj (not (hasKey $obj "Error")) (kindIs "map" $obj.metadata) -}}
    {{- $key = printf "%s/%s" (toString $obj.kind) (toString $obj.metadata.name) -}}
  {{- end -}}
  {{- if hasKey $renames $key -}}
    {{- $_ := set $seen $key true -}}
    {{- $_ := set $obj.metadata "name" (index $renames $key) -}}
    {{- if eq $obj.kind "Job" -}}
      {{- range $v := $obj.spec.template.spec.volumes | default list -}}
        {{- if and $v.configMap (eq (toString $v.configMap.name) "dcr") }}{{ $_ := set $v.configMap "name" $name }}{{ end -}}
      {{- end -}}
    {{- else if eq $obj.kind "Service" -}}
      {{- $_ := set $obj.spec "selector" (dict "job-name" $name) -}}
    {{- end -}}
    {{- $out = print $out "\n---\n" (regexFind "# Source: [^\\n]*" $doc) "\n" (toYaml $obj) -}}
  {{- else if trim $doc -}}
    {{- $out = print $out "\n---" $doc -}}
  {{- end -}}
{{- end -}}
{{- range $key := keys $renames | sortAlpha -}}
  {{- if not (hasKey $seen $key) -}}
    {{- fail (printf "okdp.vendor.oidcDcr: no %s in the rendered vendor/oidc-dcr (did the vendored chart change?)" $key) -}}
  {{- end -}}
{{- end -}}
{{- $out -}}
{{- end -}}

{{/* okdp.vendor.files: internal. Points literal .Files paths at the vendored directory. */}}
{{- define "okdp.vendor.files" -}}
{{- $prefix := printf "%s/" .dir -}}
{{- .content
    | replace ".Files.Get \"" (printf ".Files.Get \"%s" $prefix)
    | replace ".Files.Glob \"" (printf ".Files.Glob \"%s" $prefix)
    | replace ".Files.Lines \"" (printf ".Files.Lines \"%s" $prefix) -}}
{{- end -}}
