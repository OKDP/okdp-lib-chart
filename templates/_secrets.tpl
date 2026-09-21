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
                transform    optional:
                               sha256  the hex SHA-256 of the password (64 hex
                                       characters, e.g. for a 32-byte key)
                               b64enc  the base64 of the password (e.g. an
                                       Airflow Fernet key: base64 of 32 characters)
  stringData  optional map of static keys written alongside (not generated).
              Values are literal: a value containing "{{" is written as a
              template string literal, so ESO templating leaves it as is.
  labels      optional extra labels (every object and the target Secret).
  annotations optional map added to the metadata of every rendered object (the
              Password generators and the ExternalSecret), e.g.
              helm.sh/resource-policy: keep and argocd.argoproj.io/sync-options:
              Delete=false for credentials that must outlive the release. The
              target Secret is owned by the ExternalSecret: keeping the
              ExternalSecret keeps it.
  type        optional type of the target Secret (e.g. Opaque).
  namespace   optional, default the release namespace.
  refreshInterval  default "0": generated once, never rotated. ESO regenerates
              only if the ExternalSecret is recreated or the Secret deleted.
              ESO never applies a later spec change either (keys, stringData):
              change the keys by rendering a new Secret name.
  apiVersion  ExternalSecret apiVersion, default external-secrets.io/v1
              (served since ESO 0.16; ESO >= 0.17 no longer serves v1beta1).
              The Password generators stay generators.external-secrets.io/v1alpha1.

Generators are named <name>-<key> (lowercased, "_" and "." as "-"); when that
is longer than 63 characters, it is cut and suffixed with 8 hex characters of
the SHA-256 of the key, so long keys never collide.
*/}}
{{- define "okdp.generatedSecret" -}}
{{- $ctx := .ctx -}}
{{- $name := required "okdp.generatedSecret: name is required" .name -}}
{{- $ns := .namespace | default $ctx.Release.Namespace -}}
{{- $api := .apiVersion | default "external-secrets.io/v1" -}}
{{- $labels := .labels | default dict -}}
{{- $annotations := .annotations | default dict -}}
{{- $template := dict -}}
{{- range $k, $v := .stringData | default dict -}}
  {{- $s := toString $v -}}
  {{- if contains "{{" $s -}}
    {{- $_ := set $template $k (printf "{{ %q }}" $s) -}}
  {{- else -}}
    {{- $_ := set $template $k $s -}}
  {{- end -}}
{{- end -}}
{{- $dataFrom := list -}}
{{- $gens := dict -}}
{{- range $i, $spec := .keys -}}
{{- $key := required "okdp.generatedSecret: every key needs a name" $spec.key -}}
{{- $gen := printf "%s-%s" $name ($key | lower | replace "_" "-" | replace "." "-") -}}
{{- if gt (len $gen) 63 -}}
  {{- $gen = printf "%s-%s" ($gen | trunc 54 | trimSuffix "-") ($key | sha256sum | trunc 8) -}}
{{- end -}}
{{- if hasKey $gens $gen -}}
  {{- fail (printf "okdp.generatedSecret: %s: keys %q and %q give the same generator name %q" $name (index $gens $gen) $key $gen) -}}
{{- end -}}
{{- $_ := set $gens $gen $key }}
---
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: {{ $gen }}
  namespace: {{ $ns }}
  labels:
    {{- include "okdp.labels" $ctx | nindent 4 }}
  {{- with $annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  length: {{ $spec.length | default 32 }}
  digits: {{ if hasKey $spec "digits" }}{{ $spec.digits }}{{ else }}6{{ end }}
  symbols: {{ $spec.symbols | default 0 }}
  noUpper: {{ $spec.noUpper | default false }}
  allowRepeat: true
{{- $dataFrom = append $dataFrom (dict "sourceRef" (dict "generatorRef" (dict "apiVersion" "generators.external-secrets.io/v1alpha1" "kind" "Password" "name" $gen)) "rewrite" (list (dict "regexp" (dict "source" "^password$" "target" $key)))) -}}
{{- $transform := toString ($spec.transform | default "") -}}
{{- if eq $transform "sha256" -}}
  {{- $_ := set $template $key (printf "{{ index . %q | sha256sum }}" $key) -}}
{{- else if eq $transform "b64enc" -}}
  {{- $_ := set $template $key (printf "{{ index . %q | b64enc }}" $key) -}}
{{- else if $transform -}}
  {{- fail (printf "okdp.generatedSecret: unknown transform %q (supported: sha256, b64enc)" $transform) -}}
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
  {{- with $annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  refreshInterval: {{ .refreshInterval | default "0" | quote }}
  target:
    name: {{ $name }}
    creationPolicy: Owner
    template:
      engineVersion: v2
      {{- with .type }}
      type: {{ . }}
      {{- end }}
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
