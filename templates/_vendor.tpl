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
vendored directory. Partials (templates/_*, of the chart and of its library
subcharts) are loaded and, as with Helm, what they print outside a define is
discarded; templates/tests/ and NOTES.txt are skipped. A vendored
chart that bundles an application subchart is refused: vendor and render that
subchart on its own. Hooks keep their annotations, so they behave as in the
upstream chart. Objects and pod templates missing the label
app.kubernetes.io/instance get it (pass "instanceLabel" false to opt out).

  upstream  optional, opts the chart into instance-level upstream values:
            .Values.upstream.<chart> is merged over the computed values
            (see okdp.vendor.upstream). Without it they are never read.
  valuesName
            name of the values ConfigMap (see okdp.vendor.valuesConfigMap),
            default <release>-<chart>-values: give one to each render when a
            release renders the same chart twice.
  valuesConfigMap
            false: no values ConfigMap for this render.
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
{{- if hasKey . "upstream" -}}
  {{- include "okdp.vendor.upstream" (dict "ctx" $ctx "chart" $name "values" $values "options" .upstream) -}}
{{- end -}}
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
One template text, like Helm's own render of a chart: the partials (whatever
they print outside a define is dropped, up to a marker), then every
manifest at top level (so a `define` inside a manifest works and is visible to
the others), each introduced by a separator printed by an action (so the
whitespace trimming of the upstream `{{-`/`-}}` cannot eat it). Manifests
without a `define` are also registered under their path, for
`include (print $.Template.BasePath "/x.yaml") .` (checksum annotations).
*/ -}}
{{- $bundle := "" -}}
{{- $marker := "@@okdp.vendor.render: end of partials@@" -}}
{{- range $path := $partials -}}
  {{- $bundle = print $bundle (include "okdp.vendor.files" (dict "content" ($ctx.Files.Get $path) "dir" $dir)) "\n" -}}
{{- end -}}
{{- range $path := $manifests -}}
  {{- $content := include "okdp.vendor.files" (dict "content" ($ctx.Files.Get $path) "dir" $dir) -}}
  {{- if not (regexMatch "{{-?\\s*define\\s" $content) -}}
    {{- $bundle = print $bundle "{{ define " (quote $path) " }}" $content "{{ end }}\n" -}}
  {{- end -}}
{{- end -}}
{{- $bundle = print $bundle "{{ " (quote $marker) " }}" -}}
{{- range $path := $manifests -}}
  {{- $bundle = print $bundle "{{ " (quote (printf "\n---\n# Source: %s\n" $path)) " }}" (include "okdp.vendor.files" (dict "content" ($ctx.Files.Get $path) "dir" $dir)) -}}
{{- end -}}
{{- /* Helm discards what partials print outside their defines: so do we. */ -}}
{{- $rendered := (splitn $marker 2 (tpl $bundle $root))._1 -}}
{{- $rendered = print $rendered (include "okdp.vendor.valuesConfigMap" (dict "ctx" $ctx "chart" $name "meta" $meta "values" $values "name" .valuesName "enabled" .valuesConfigMap)) -}}
{{- if eq (toString (.instanceLabel | default "true")) "false" -}}
{{- $rendered -}}
{{- else -}}
{{- include "okdp.vendor.instanceLabel" (dict "rendered" $rendered "release" $ctx.Release.Name) -}}
{{- end -}}
{{- end -}}

{{/*
okdp.vendor.valuesConfigMap: internal to okdp.vendor.render. The values the
vendored chart was rendered with (vendored defaults, computed values, instance
upstream values and global, merged: what a plain Helm install of the upstream
chart would take as values.yaml), as a ConfigMap <release>-<chart>-values
with key values.yaml. It makes the otherwise invisible second stage of the
render auditable: `helm get manifest`, an Argo CD diff, `kubectl get cm` or an
offline `helm template` (scripts/show-values.sh of platform-charts) show it,
and a change of the computed values shows up as a change of this object.

  label       okdp.io/vendor-values: <chart>
  annotation  okdp.io/vendor-chart: <name>-<version> (of vendor/<chart>/Chart.yaml)

The values never carry secrets by OKDP convention (Secrets are referenced,
generated by ESO, or placeholders a wrapper re-points), but they do carry the
vendored defaults and the instance's upstream values as written: a platform
whose readers of ConfigMaps must not see them sets
global.okdp.vendor.valuesConfigMap: false. A wrapper turns it off for one
render with "valuesConfigMap" false. Nothing reads it: deleting it changes
nothing but the audit trail.
*/}}
{{- define "okdp.vendor.valuesConfigMap" -}}
{{- $ctx := .ctx -}}
{{- $platform := (include "okdp.platform.get" (dict "ctx" $ctx "path" "vendor.valuesConfigMap") | fromYaml).v -}}
{{- if and (ne (toString .enabled) "false") (ne (toString $platform) "false") -}}
{{- $name := .name | default (printf "%s-%s-values" $ctx.Release.Name .chart | trunc 253 | trimSuffix "-") }}
---
# Source: {{ $ctx.Chart.Name }}/vendor/{{ .chart }}/values.yaml (okdp.vendor.render)
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $name }}
  labels:
    {{- include "okdp.labels" (dict "ctx" $ctx "component" "vendor-values") | nindent 4 }}
    okdp.io/vendor-values: {{ .chart | quote }}
  annotations:
    okdp.io/vendor-chart: {{ printf "%s-%s" (toString .meta.name) (toString .meta.version) | quote }}
data:
  values.yaml: |
    {{- toYaml .values | nindent 4 }}
{{- end -}}
{{- end -}}

{{/*
okdp.vendor.upstream: internal to okdp.vendor.render. Merges the instance's
values of a vendored chart, .Values.upstream.<key>, over its computed values
(`values`, changed in place). The instance wins, so it can set any value of
the upstream chart, except where the wrapper protects it.

  {{ include "okdp.vendor.render" (dict "ctx" $ "chart" "trino" "values" $v
       "upstream" (dict "protect" (list "fullnameOverride" "server.config")
                        "append" (list "env"))) }}

Options (the `upstream` argument of okdp.vendor.render, a dict, may be empty):
  key      the key under .Values.upstream; default: the chart.
  protect  dotted paths the instance must not set: setting the path, anything
           under it, or a non-map on the way to it fails the render.
           `global` (the platform values) is always protected.
  append   dotted paths of lists: the instance's list is appended to the
           computed one instead of replacing it (e.g. an env list carrying the
           wrapper's secrets). A path cannot be both protected and appended.
Otherwise as for `values`: maps merge, lists and scalars replace, a null
clears the key. A key or value containing "{{" is refused: upstream charts
pass some values to tpl (Trino's catalogs, labels), where template code could
call lookup under Flux and read any Secret of the cluster. Path segments are map keys split on "." (no list index, no
key containing a dot). What an instance may set is declared by the chart's
values.schema.json (property `upstream`); this helper enforces what it may not.
*/}}
{{- define "okdp.vendor.upstream" -}}
{{- $ctx := .ctx -}}
{{- $opts := .options | default dict -}}
{{- if not (kindIs "map" $opts) -}}
  {{- fail (printf "%s: okdp.vendor.render %s: upstream must be a dict" $ctx.Chart.Name .chart) -}}
{{- end -}}
{{- range $k, $_ := $opts -}}
  {{- if not (has $k (list "key" "protect" "append")) -}}
    {{- fail (printf "%s: okdp.vendor.render: unknown upstream option %q (key, protect, append)" $ctx.Chart.Name $k) -}}
  {{- end -}}
{{- end -}}
{{- $key := $opts.key | default .chart -}}
{{- $appends := $opts.append | default list -}}
{{- $all := $ctx.Values.upstream | default dict -}}
{{- if not (kindIs "map" $all) -}}
  {{- fail (printf "%s: upstream must be a map of vendored chart names to values" $ctx.Chart.Name) -}}
{{- end -}}
{{- $where := printf "%s: upstream.%s" $ctx.Chart.Name $key -}}
{{- $user := index $all $key -}}
{{- if and $user (not (kindIs "map" $user)) -}}
  {{- fail (printf "%s must be a map of values of the vendored chart" $where) -}}
{{- end -}}
{{- if $user -}}
{{- if contains "{{" (toJson $user) -}}
  {{- fail (printf "%s: a key or value contains \"{{\": upstream charts pass some values to tpl, so an instance may not write template code" $where) -}}
{{- end -}}
{{- $user = deepCopy $user -}}
{{- range $p := concat (list "global") ($opts.protect | default list) -}}
  {{- if has $p $appends -}}
    {{- fail (printf "%s: okdp.vendor.render: %s is both protected and appended" $ctx.Chart.Name $p) -}}
  {{- end -}}
  {{- $parts := splitList "." $p -}}
  {{- $node := $user -}}
  {{- $done := false -}}
  {{- range $i, $part := $parts -}}
    {{- if and (not $done) (hasKey $node $part) -}}
      {{- $v := index $node $part -}}
      {{- if or (eq (add1 $i) (len $parts)) (not (kindIs "map" $v)) -}}
        {{- fail (printf "%s.%s: %s is set by the platform and cannot be changed" $where (join "." (slice $parts 0 (add1 $i))) $p) -}}
      {{- end -}}
      {{- $node = $v -}}
    {{- else -}}
      {{- $done = true -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- range $p := $appends -}}
  {{- $parts := splitList "." $p -}}
  {{- $last := last $parts -}}
  {{- $unode := $user -}}
  {{- $vnode := $.values -}}
  {{- $found := true -}}
  {{- range $part := initial $parts -}}
    {{- if and $found (kindIs "map" (index $unode $part)) -}}
      {{- $unode = index $unode $part -}}
      {{- if kindIs "map" $vnode }}{{ $vnode = index $vnode $part }}{{ end -}}
    {{- else -}}
      {{- $found = false -}}
    {{- end -}}
  {{- end -}}
  {{- if and $found (hasKey $unode $last) -}}
    {{- $add := index $unode $last -}}
    {{- if not (kindIs "slice" $add) -}}
      {{- fail (printf "%s.%s must be a list: it is appended to the one the platform sets" $where $p) -}}
    {{- end -}}
    {{- $base := list -}}
    {{- if and (kindIs "map" $vnode) (hasKey $vnode $last) -}}
      {{- $computed := index $vnode $last -}}
      {{- if kindIs "slice" $computed -}}
        {{- $base = $computed -}}
      {{- else if not (kindIs "invalid" $computed) -}}
        {{- fail (printf "%s.%s: the computed value is not a list (did the vendored chart change?)" $where $p) -}}
      {{- end -}}
    {{- end -}}
    {{- $_ := set $unode $last (concat $base $add) -}}
  {{- end -}}
{{- end -}}
{{- $_ := mergeOverwrite .values $user -}}
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
okdp.vendor.secretKeyRef: rewrites an okdp.vendor.render stream, for upstream
charts that hard-wire a secretKeyRef to a Secret they generate themselves
(lookup + rand*) with no value to point it elsewhere (JupyterHub's proxy
token): the wrapper feeds the chart a placeholder and re-points the
references to an ESO-generated Secret. Returns the rendered stream with every container env
`valueFrom.secretKeyRef` {name: <name>, key: <key>} of the workload pod
templates (Deployment, StatefulSet, DaemonSet, ReplicaSet, Job, CronJob;
containers and initContainers) re-pointed to Secret <to> (key <toKey>,
default <key>). Documents without such a reference are passed through
untouched; the others are re-serialised (same content, keys sorted, comments
dropped). Fails when nothing was re-pointed: the upstream chart changed.

  {{- $out := include "okdp.vendor.render" (dict "ctx" $ "chart" "x" "values" $v) }}
  {{ include "okdp.vendor.secretKeyRef" (dict "rendered" $out "name" "x-hub" "key" "token" "to" "x-generated") }}
*/}}
{{- define "okdp.vendor.secretKeyRef" -}}
{{- $from := required "okdp.vendor.secretKeyRef: name is required" .name -}}
{{- $key := required "okdp.vendor.secretKeyRef: key is required" .key -}}
{{- $to := required "okdp.vendor.secretKeyRef: to is required" .to -}}
{{- $toKey := .toKey | default $key -}}
{{- $count := 0 -}}
{{- $out := "" -}}
{{- range $doc := regexSplit "(?m)^---[ \\t]*$" .rendered -1 -}}
  {{- $obj := fromYaml $doc -}}
  {{- $changed := false -}}
  {{- if and $obj (not (hasKey $obj "Error")) -}}
    {{- $pod := dict -}}
    {{- if has (toString $obj.kind) (list "Deployment" "StatefulSet" "DaemonSet" "ReplicaSet" "Job") -}}
      {{- $pod = ((($obj.spec | default dict).template | default dict).spec) | default dict -}}
    {{- else if eq (toString $obj.kind) "CronJob" -}}
      {{- $pod = ((((($obj.spec | default dict).jobTemplate | default dict).spec | default dict).template | default dict).spec) | default dict -}}
    {{- end -}}
    {{- range $list := list ($pod.containers | default list) ($pod.initContainers | default list) -}}
      {{- range $c := $list -}}
        {{- range $e := $c.env | default list -}}
          {{- $ref := (($e.valueFrom | default dict).secretKeyRef) | default dict -}}
          {{- if and (eq (toString $ref.name) $from) (eq (toString $ref.key) $key) -}}
            {{- $_ := set $ref "name" $to -}}
            {{- $_ := set $ref "key" $toKey -}}
            {{- $changed = true -}}
            {{- $count = add1 $count -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- if $changed -}}
    {{- $out = print $out "\n---\n" (regexFind "# Source: [^\\n]*" $doc) "\n" (toYaml $obj) -}}
  {{- else if trim $doc -}}
    {{- $out = print $out "\n---" $doc -}}
  {{- end -}}
{{- end -}}
{{- if eq $count 0 -}}
  {{- fail (printf "okdp.vendor.secretKeyRef: no secretKeyRef %s/%s in the rendered workloads (did the vendored chart change?)" $from $key) -}}
{{- end -}}
{{- $out -}}
{{- end -}}

{{/*
okdp.vendor.crds: the CRDs of the chart unpacked under vendor/<chart>/crds/
(every *.yaml / *.yml file, sub-directories included), as regular objects.

  {{ include "okdp.vendor.crds" (dict "ctx" $ "chart" "spark-operator") }}

Helm installs the crds/ directory of the chart being installed only, never of
a vendored one, and okdp.vendor.render renders templates/. Each CRD gets
  helm.sh/resource-policy: keep                               uninstalling the release
                                                              must not delete the CRDs
                                                              (and every custom resource)
  argocd.argoproj.io/sync-options: Delete=false,ServerSideApply=true
                                                              the same for Argo; large
                                                              CRDs exceed the client-side
                                                              apply annotation
and is upgraded with the chart (unlike crds/). The files are not templates.
The annotations are inserted as text when the layout allows it (large CRDs
are not re-serialised), otherwise the document is parsed and re-serialised.
A chart must not create custom resources of a CRD it installs in the same
release: split it into layered components.
*/}}
{{- define "okdp.vendor.crds" -}}
{{- $ctx := .ctx -}}
{{- $name := required "okdp.vendor.crds: chart is required" .chart -}}
{{- $dir := printf "vendor/%s/crds" $name -}}
{{- $keep := dict "helm.sh/resource-policy" "keep" "argocd.argoproj.io/sync-options" "Delete=false,ServerSideApply=true" -}}
{{- $insert := "    helm.sh/resource-policy: keep\n    argocd.argoproj.io/sync-options: Delete=false,ServerSideApply=true\n" -}}
{{- $count := 0 -}}
{{- range $path, $_ := $ctx.Files.Glob (printf "%s/**" $dir) -}}
  {{- if regexMatch "\\.ya?ml$" $path -}}
  {{- range $doc := regexSplit "(?m)^---[ \\t]*$" ($ctx.Files.Get $path) -1 -}}
    {{- $clean := regexReplaceAll "(?m)^#.*\\n?" $doc "" | trim -}}
    {{- if $clean -}}
      {{- if not (regexMatch "(?m)^kind:[ \\t]*[\"']?CustomResourceDefinition[\"']?[ \\t]*$" $clean) -}}
        {{- fail (printf "okdp.vendor.crds: %s: not a CustomResourceDefinition" $path) -}}
      {{- end -}}
      {{- $count = add1 $count -}}
      {{- $text := "" -}}
      {{- if regexMatch "helm\\.sh/resource-policy|argocd\\.argoproj\\.io/sync-options" $clean -}}
      {{- else if regexMatch "(?m)^metadata:\\n  annotations:\\n" $clean -}}
        {{- $text = regexReplaceAll "(?m)^metadata:\\n  annotations:\\n" $clean (printf "metadata:\n  annotations:\n%s" $insert) -}}
      {{- else if and (regexMatch "(?m)^metadata:\\n" $clean) (not (regexMatch "(?m)^  annotations:" $clean)) -}}
        {{- $text = regexReplaceAll "(?m)^metadata:\\n" $clean (printf "metadata:\n  annotations:\n%s" $insert) -}}
      {{- end -}}
      {{- if not $text -}}
        {{- $obj := fromYaml $clean -}}
        {{- if hasKey $obj "Error" -}}
          {{- fail (printf "okdp.vendor.crds: %s: %s" $path $obj.Error) -}}
        {{- end -}}
        {{- $meta := $obj.metadata -}}
        {{- $_ := set $meta "annotations" (merge (deepCopy $keep) ($meta.annotations | default dict)) -}}
        {{- $text = toYaml $obj -}}
      {{- end }}
---
# Source: {{ $path }}
{{ $text }}
    {{- end -}}
  {{- end -}}
  {{- end -}}
{{- end -}}
{{- if eq $count 0 -}}
  {{- fail (printf "okdp.vendor.crds: no CRD under %s (run scripts/vendor-charts.sh %s)" $dir $ctx.Chart.Name) -}}
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
which this helper sets. The Job image defaults to a pinned Alpine (the chart's
default is alpine:latest; the script still installs its tools with apk at
runtime); values.image overrides it. The renamed documents are re-serialised (same content,
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
{{- if not $values.image -}}
  {{- $_ := set $values "image" "docker.io/library/alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6" -}}
{{- end -}}
{{- $rendered := include "okdp.vendor.render" (dict "ctx" $ctx "chart" "oidc-dcr" "values" $values "valuesName" (printf "%s-values" $name)) -}}
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
