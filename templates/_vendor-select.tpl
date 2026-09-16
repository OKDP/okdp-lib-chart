{{/*
Copyright 2026 The OKDP Authors.
Licensed under the Apache License, Version 2.0.

Selecting objects in the output of okdp.vendor.render.

Why: some upstream charts render an object the wrapper must own instead, and
offer no value to switch it off. JupyterHub always renders its hub Secret,
whose passwords come from `lookup` + `randAlphaNum`: the wrapper feeds the
chart placeholders (so nothing random is rendered), takes the Secret out of
the stream, and renders an ESO-generated Secret of the same name carrying the
same non-secret keys.
*/}}

{{/*
okdp.vendor.object: the first object of a rendered stream with the given kind
and metadata.name, as YAML (use fromYaml). Empty when there is none.

  {{- $out := include "okdp.vendor.render" (dict "ctx" $ "chart" "x" "values" $v) }}
  {{- $secret := include "okdp.vendor.object" (dict "rendered" $out "kind" "Secret" "name" "x-hub") | fromYaml }}
*/}}
{{- define "okdp.vendor.object" -}}
{{- $kind := required "okdp.vendor.object: kind is required" .kind -}}
{{- $name := required "okdp.vendor.object: name is required" .name -}}
{{- $found := "" -}}
{{- range $doc := regexSplit "(?m)^---[ \\t]*$" .rendered -1 -}}
  {{- if not $found -}}
    {{- $obj := fromYaml $doc -}}
    {{- if and $obj (not (hasKey $obj "Error")) (eq (toString $obj.kind) $kind) (kindIs "map" $obj.metadata) (eq (toString $obj.metadata.name) $name) -}}
      {{- $found = toYaml $obj -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $found -}}
{{- end -}}

{{/*
okdp.vendor.withoutObject: the rendered stream without the objects of the
given kind and metadata.name. The other documents are passed through
untouched.

  {{ include "okdp.vendor.withoutObject" (dict "rendered" $out "kind" "Secret" "name" "x-hub") }}
*/}}
{{- define "okdp.vendor.withoutObject" -}}
{{- $kind := required "okdp.vendor.withoutObject: kind is required" .kind -}}
{{- $name := required "okdp.vendor.withoutObject: name is required" .name -}}
{{- range $doc := regexSplit "(?m)^---[ \\t]*$" .rendered -1 -}}
  {{- $obj := fromYaml $doc -}}
  {{- if and $obj (not (hasKey $obj "Error")) (eq (toString $obj.kind) $kind) (kindIs "map" $obj.metadata) (eq (toString $obj.metadata.name) $name) -}}
  {{- else if trim $doc -}}
{{ print "\n---" $doc }}
  {{- end -}}
{{- end -}}
{{- end -}}
