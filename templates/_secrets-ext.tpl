{{/*
Copyright 2026 The OKDP Authors.
Licensed under the Apache License, Version 2.0.

Extension of okdp.generatedSecret, kept in its own file so _secrets.tpl
stays unchanged. Candidate for folding into okdp.generatedSecret.
*/}}

{{/*
okdp.generatedSecretExt: okdp.generatedSecret with two extra options.

  {{ include "okdp.generatedSecretExt" (dict "ctx" $ "name" "x"
       "keys" (list (dict "key" "fernet-key" "length" 32 "transform" "b64enc"))
       "annotations" (dict "helm.sh/resource-policy" "keep")) }}

Arguments: those of okdp.generatedSecret, plus
  keys[].transform  also accepts "b64enc": the Secret key holds the base64 of
                    the generated password (e.g. an Airflow Fernet key: the
                    base64 of 32 characters, 44 characters). "sha256" and no
                    transform behave as in okdp.generatedSecret.
  annotations       map added to the metadata of every rendered object (the
                    Password generators and the ExternalSecret), e.g.
                    helm.sh/resource-policy: keep and
                    argocd.argoproj.io/sync-options: Delete=false for
                    credentials that must outlive the release (the former
                    internal-secrets `keep: true`). The target Secret is owned
                    by the ExternalSecret: keeping the ExternalSecret keeps it.

Documents are re-serialised (keys sorted) only when one of the two options
is used; otherwise the output is okdp.generatedSecret's, byte for byte.
*/}}
{{- define "okdp.generatedSecretExt" -}}
{{- $args := deepCopy (omit . "ctx" "annotations") -}}
{{- $_ := set $args "ctx" .ctx -}}
{{- $b64 := list -}}
{{- $keys := list -}}
{{- range $spec := .keys -}}
  {{- if eq (toString ($spec.transform | default "")) "b64enc" -}}
    {{- $b64 = append $b64 $spec.key -}}
    {{- $keys = append $keys (omit $spec "transform") -}}
  {{- else -}}
    {{- $keys = append $keys $spec -}}
  {{- end -}}
{{- end -}}
{{- $_ := set $args "keys" $keys -}}
{{- $out := include "okdp.generatedSecret" $args -}}
{{- if and (not $b64) (not .annotations) -}}
{{ $out }}
{{- else -}}
{{- $annotations := .annotations | default dict -}}
{{- range $doc := regexSplit "(?m)^---[ \\t]*$" $out -1 -}}
  {{- if trim $doc -}}
    {{- $obj := fromYaml $doc -}}
    {{- if hasKey $obj "Error" -}}
      {{- fail (printf "okdp.generatedSecretExt: cannot parse okdp.generatedSecret output: %s" $obj.Error) -}}
    {{- end -}}
    {{- if $annotations -}}
      {{- $meta := $obj.metadata -}}
      {{- $_ := set $meta "annotations" (merge (deepCopy $annotations) ($meta.annotations | default dict)) -}}
    {{- end -}}
    {{- if eq (toString $obj.kind) "ExternalSecret" -}}
      {{- $data := $obj.spec.target.template.data -}}
      {{- range $k := $b64 -}}
        {{- $_ := set $data $k (printf "{{ index . %q | b64enc }}" $k) -}}
      {{- end -}}
    {{- end }}
---
{{ toYaml $obj }}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
