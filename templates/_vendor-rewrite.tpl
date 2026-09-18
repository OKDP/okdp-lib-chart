{{/*
Copyright 2026 The OKDP Authors.
Licensed under the Apache License, Version 2.0.

Rewriting the output of okdp.vendor.render.

Why: some upstream charts hard-wire a secretKeyRef to a Secret they generate
themselves with `lookup` + rand*, and offer no value to point it elsewhere.
JupyterHub reads its proxy token from its own hub Secret: the wrapper feeds
the chart a placeholder (so nothing random is rendered) and re-points the
references to an ESO-generated Secret.
*/}}

{{/*
okdp.vendor.secretKeyRef: the rendered stream with every container env
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
