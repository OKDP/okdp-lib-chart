{{/*
Copyright 2026 The OKDP Authors.
Licensed under the Apache License, Version 2.0.

Provider side of the contracts: the connections an instance publishes.
Replaces the KuboCD package `outputs`.
*/}}

{{/*
okdp.contract.provide: declares one connection this instance provides, as a
one-item YAML list. Call it (or its per-contract shortcut) from the chart's
"okdp.instance.outputs" template; okdp.descriptor publishes the entries in the
descriptor ConfigMap and renders their credentials Secrets.

  {{- define "okdp.instance.outputs" -}}
  {{ include "okdp.contract.hive.provide" (dict "ctx" $ "values" (dict "thriftUri" $uri)) }}
  {{- end -}}

Arguments:
  ctx       the root context ($).
  contract  the contract (implied by the okdp.contract.<contract>.provide shortcuts).
  values    the contract's non-secret fields. Defaults and derived fields are
            filled in, required fields checked, secret fields refused.
  name      optional, the connection name. Default: the release name, which is
            what internal references (okdp.connection) resolve.
  secretRef optional, the name of the credentials Secret consumers use. The
            entry has no secretRef unless one is given here or `secret` is
            (then default <name>-<contract>-credentials): an output never
            points at a Secret that nobody creates.
  secret    optional, how the chart renders that Secret (see okdp.descriptor):
              {stringData: {<key>: <value>}}             a plain Secret
              {generate: [<okdp.generatedSecret key>], stringData: {...}}
                                                         ESO Password generator + ExternalSecret
            Leave it out when the Secret is created by something else (an
            upstream chart, an operator) under the secretRef name, or when the
            contract has no secret field.

When name is the release name and the contract has an internal naming
convention (x-okdp-internal), the values must match it: that is the guarantee
that a consumer referencing this instance by name gets the same fields.
*/}}
{{- define "okdp.contract.provide" -}}
{{- $ctx := .ctx -}}
{{- $contract := .contract -}}
{{- $schema := include "okdp.contract.schema" (dict "contract" $contract) | fromJson -}}
{{- $_ := set $schema "_contract" $contract -}}
{{- $name := .name | default $ctx.Release.Name -}}
{{- $where := printf "%s: output %q (%s)" $ctx.Chart.Name $name $contract -}}
{{- $values := deepCopy (.values | default dict) -}}
{{- range $k, $v := $values -}}
  {{- if not (hasKey $schema.properties $k) -}}
    {{- fail (printf "%s: field %q is not part of the %s contract" $where $k $contract) -}}
  {{- end -}}
  {{- if index (index $schema.properties $k) "x-okdp-secret" -}}
    {{- fail (printf "%s: %q is a secret field, put it in the credentials Secret" $where $k) -}}
  {{- end -}}
{{- end -}}
{{- include "okdp.contract.complete" (dict "schema" $schema "values" $values "where" $where) -}}
{{- $conv := index $schema "x-okdp-internal" -}}
{{- if and $conv (eq $name $ctx.Release.Name) -}}
  {{- $expected := include "okdp.connection" (dict "ctx" (dict "Values" (dict "global" $ctx.Values.global) "Release" $ctx.Release "Chart" $ctx.Chart) "ref" $name "contract" $contract) | fromYaml -}}
  {{- range $k, $_ := $conv -}}
    {{- if ne (toString (index $values $k)) (toString (index $expected $k)) -}}
      {{- fail (printf "%s: %s is %q but internal references to %q resolve it to %q (x-okdp-internal of the %s contract)" $where $k (toString (index $values $k)) $name (toString (index $expected $k)) $contract) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- $entry := dict "name" $name "contract" $contract "values" $values -}}
{{- if or .secretRef .secret -}}
  {{- $_ := set $entry "secretRef" (dict "name" (.secretRef | default (printf "%s-%s-credentials" $name $contract))) -}}
{{- end -}}
{{- with .secret }}{{ $_ := set $entry "secret" . }}{{ end -}}
{{- toYaml (list $entry) -}}
{{- end -}}

{{/* Per-contract shortcuts: same arguments as okdp.contract.provide, without "contract". */}}
{{- define "okdp.contract.database-server.provide" -}}
{{- include "okdp.contract.provide" (merge (dict "contract" "database-server") .) -}}
{{- end -}}
{{- define "okdp.contract.s3.provide" -}}
{{- include "okdp.contract.provide" (merge (dict "contract" "s3") .) -}}
{{- end -}}
{{- define "okdp.contract.hive.provide" -}}
{{- include "okdp.contract.provide" (merge (dict "contract" "hive") .) -}}
{{- end -}}
{{- define "okdp.contract.iceberg-catalog.provide" -}}
{{- include "okdp.contract.provide" (merge (dict "contract" "iceberg-catalog") .) -}}
{{- end -}}
{{- define "okdp.contract.trino.provide" -}}
{{- include "okdp.contract.provide" (merge (dict "contract" "trino") .) -}}
{{- end -}}
