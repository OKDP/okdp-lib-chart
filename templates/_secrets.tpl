{{/*
Copyright 2026 The OKDP Authors.
Licensed under the Apache License, Version 2.0.

Generated secrets. Helm must render the same output on every run (Argo renders
with `helm template`, which cannot read back the cluster), so random values
are never produced by the chart: an External Secrets Operator Password
generator produces them in the cluster, once.
*/}}

{{/*
okdp.generatedSecret: an ESO Password generator per generated key plus one
ExternalSecret that writes the Secret "name" in the release namespace.

  {{ include "okdp.generatedSecret" (dict "ctx" $ "name" (printf "%s-internal" .Release.Name)
       "keys" (list (dict "key" "shared-secret" "length" 32))) }}

Arguments:
  ctx         the root context ($).
  name        the Secret (and ExternalSecret) name.
  keys        list of generated keys:
                key          the Secret key (required)
                length       default 32
                digits       default 6
                symbols      default 0 (symbols break URLs and .properties files)
                noUpper      default false
                transform    optional: "sha256" stores the hex SHA-256 of the
                             password (64 hex characters, e.g. for a 32-byte key)
  stringData  optional map of static keys written alongside (not generated).
  labels      optional extra labels.
  namespace   optional, default the release namespace.
  refreshInterval  default "0": generated once, never rotated. ESO regenerates
              only if the ExternalSecret is recreated or the Secret deleted.
              ESO never applies a later spec change either (keys, stringData):
              change the keys by rendering a new Secret name.
  apiVersion  ExternalSecret apiVersion, default external-secrets.io/v1
              (served since ESO 0.16; ESO >= 0.17 no longer serves v1beta1).
              The Password generators stay generators.external-secrets.io/v1alpha1.
*/}}
{{- define "okdp.generatedSecret" -}}
{{- $ctx := .ctx -}}
{{- $name := required "okdp.generatedSecret: name is required" .name -}}
{{- $ns := .namespace | default $ctx.Release.Namespace -}}
{{- $api := .apiVersion | default "external-secrets.io/v1" -}}
{{- $labels := .labels | default dict -}}
{{- $template := dict -}}
{{- range $k, $v := .stringData | default dict -}}
  {{- $_ := set $template $k (toString $v) -}}
{{- end -}}
{{- $dataFrom := list -}}
{{- range $i, $spec := .keys -}}
{{- $key := required "okdp.generatedSecret: every key needs a name" $spec.key -}}
{{- $gen := printf "%s-%s" $name ($key | lower | replace "_" "-" | replace "." "-") | trunc 63 | trimSuffix "-" }}
---
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: {{ $gen }}
  namespace: {{ $ns }}
  labels:
    {{- include "okdp.labels" $ctx | nindent 4 }}
spec:
  length: {{ $spec.length | default 32 }}
  digits: {{ if hasKey $spec "digits" }}{{ $spec.digits }}{{ else }}6{{ end }}
  symbols: {{ $spec.symbols | default 0 }}
  noUpper: {{ $spec.noUpper | default false }}
  allowRepeat: true
{{- $dataFrom = append $dataFrom (dict "sourceRef" (dict "generatorRef" (dict "apiVersion" "generators.external-secrets.io/v1alpha1" "kind" "Password" "name" $gen)) "rewrite" (list (dict "regexp" (dict "source" "^password$" "target" $key)))) -}}
{{- if eq ($spec.transform | default "") "sha256" -}}
  {{- $_ := set $template $key (printf "{{ index . %q | sha256sum }}" $key) -}}
{{- else if $spec.transform -}}
  {{- fail (printf "okdp.generatedSecret: unknown transform %q (supported: sha256)" $spec.transform) -}}
{{- else -}}
  {{- $_ := set $template $key (printf "{{ index . %q }}" $key) -}}
{{- end -}}
{{- end }}
---
apiVersion: {{ $api }}
kind: ExternalSecret
metadata:
  name: {{ $name }}
  namespace: {{ $ns }}
  labels:
    {{- include "okdp.labels" $ctx | nindent 4 }}
    {{- with $labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  refreshInterval: {{ .refreshInterval | default "0" | quote }}
  target:
    name: {{ $name }}
    creationPolicy: Owner
    template:
      engineVersion: v2
      metadata:
        labels:
          {{- include "okdp.labels" $ctx | nindent 10 }}
          {{- with $labels }}
          {{- toYaml . | nindent 10 }}
          {{- end }}
      data:
        {{- toYaml $template | nindent 8 }}
  dataFrom:
    {{- toYaml $dataFrom | nindent 4 }}
{{- end -}}
