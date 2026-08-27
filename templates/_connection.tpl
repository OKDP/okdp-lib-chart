{{/*
Copyright 2026 The OKDP Authors.
Licensed under the Apache License, Version 2.0.

Contracts and connections. Replaces the KuboCD Contract/Connection CRDs and
the connectionRef parameter type.
*/}}

{{/*
okdp.contract.schema: the JSON schema of one contract (from
contracts/<contract>.schema.json, embedded by hack/gen-contracts.sh), as JSON.
Fails on an unknown contract.
  {{- $schema := include "okdp.contract.schema" (dict "contract" "hive") | fromJson }}
*/}}
{{- define "okdp.contract.schema" -}}
{{- $all := include "okdp.contracts" . | fromJson -}}
{{- if not (hasKey $all .contract) -}}
  {{- fail (printf "unknown OKDP contract %q (known: %s)" .contract (keys $all | sortAlpha | join ", ")) -}}
{{- end -}}
{{- index $all .contract | toJson -}}
{{- end -}}

{{/*
okdp.contract.complete: internal. Applies derived fields and defaults, then
checks the required ones. Args: {schema, values (dict, modified in place),
where (message prefix)}. Renders nothing.
*/}}
{{- define "okdp.contract.complete" -}}
{{- $props := .schema.properties -}}
{{- $v := .values -}}
{{- /* Pass 1: defaults. Pass 2: fields derived from another (after its default). */ -}}
{{- range $pass := list "default" "derived" -}}
{{- range $name := keys $props | sortAlpha -}}
  {{- $p := index $props $name -}}
  {{- if and (not (hasKey $v $name)) (not (index $p "x-okdp-secret")) -}}
    {{- $derived := index $p "x-okdp-derived" -}}
    {{- if and (eq $pass "derived") $derived (hasKey $v $derived.from) -}}
      {{- $src := toString (index $v $derived.from) -}}
      {{- if hasKey $derived.map $src }}{{ $_ := set $v $name (index $derived.map $src) }}{{ end -}}
    {{- else if and (eq $pass "default") (not $derived) (hasKey $p "default") -}}
      {{- $cond := index $p "x-ui-condition" -}}
      {{- if or (not $cond) (eq (toString (index $v $cond.field)) (toString $cond.value)) -}}
        {{- $_ := set $v $name (index $p "default") -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- range $name := .schema.required | default list -}}
  {{- if or (not (hasKey $v $name)) (kindIs "invalid" (index $v $name)) (eq (toString (index $v $name)) "") -}}
    {{- fail (printf "%s: field %q is required by the %s contract" $.where $name $.schema._contract) -}}
  {{- end -}}
{{- end -}}
{{- range $name, $val := $v -}}
  {{- $p := index $props $name -}}
  {{- if and $p.enum (not (has (toString $val) $p.enum)) -}}
    {{- fail (printf "%s: field %q is %q, the %s contract allows %s" $.where $name (toString $val) $.schema._contract (join ", " $p.enum)) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
okdp.connection: resolves a connection reference into the fields of its
contract, as YAML (use fromYaml).

  {{- $hive := include "okdp.connection" (dict "ref" .metastore "contract" "hive" "ctx" $) | fromYaml }}
  thrift: {{ $hive.thriftUri }}
  secret: {{ $hive.secretRef.name }}

Arguments:
  ref       the reference: a key of .Values.connections, or the release name of
            an OKDP instance in the same namespace.
  contract  the contract the caller codes against.
  ctx       the root context ($).
  field     optional, the parameter path, used in error messages.

Resolution:
  1. .Values.connections.<ref> (external connection, one values layer per
     projects/<project>/connections/<name>.yaml). Its `contract` must match.
     Secret fields must not be there (they live in the Secret of secretRef).
  2. otherwise an internal OKDP instance named <ref> in the release namespace:
     the fields come from the contract's naming convention (x-okdp-internal in
     the contract schema, placeholders ${ref} ${namespace} ${suffix}), and
     secretRef.name is <ref>-<contract>-credentials. Contracts without a
     naming convention (s3, database-server) must be declared as connections.
Then derived fields (x-okdp-derived) and defaults are filled in and the
required fields checked.

Result: the contract's non-secret fields, plus
  secretRef: {name: ...}   when known (always for internal references)
  okdp: {ref, contract, source: external|internal}
*/}}
{{- define "okdp.connection" -}}
{{- $ctx := .ctx -}}
{{- $contract := .contract | default "" -}}
{{- $ref := .ref | default "" | toString -}}
{{- $where := printf "%s: %s" $ctx.Chart.Name (.field | default (printf "%s connection" $contract)) -}}
{{- if not $contract }}{{ fail (printf "%s: okdp.connection needs a contract" $where) }}{{ end -}}
{{- $schema := include "okdp.contract.schema" (dict "contract" $contract) | fromJson -}}
{{- $_ := set $schema "_contract" $contract -}}
{{- if not $ref -}}
  {{- fail (printf "%s: no %s connection given" $where $contract) -}}
{{- end -}}
{{- $conns := $ctx.Values.connections | default dict -}}
{{- $out := dict -}}
{{- $source := "internal" -}}
{{- if hasKey $conns $ref -}}
  {{- $source = "external" -}}
  {{- $c := index $conns $ref -}}
  {{- if not (kindIs "map" $c) -}}
    {{- fail (printf "%s: connections.%s must be a map" $where $ref) -}}
  {{- end -}}
  {{- if ne (toString $c.contract) $contract -}}
    {{- fail (printf "%s: connection %q has contract %q, %q is expected" $where $ref (toString $c.contract) $contract) -}}
  {{- end -}}
  {{- range $k, $val := $c -}}
    {{- if has $k (list "contract" "secretRef" "description") -}}
    {{- else if not (hasKey $schema.properties $k) -}}
      {{- fail (printf "%s: connection %q: field %q is not part of the %s contract" $where $ref $k $contract) -}}
    {{- else if index (index $schema.properties $k) "x-okdp-secret" -}}
      {{- fail (printf "%s: connection %q: %q is a secret field, it belongs in the Secret named by secretRef, not in values" $where $ref $k) -}}
    {{- else -}}
      {{- $_ := set $out $k $val -}}
    {{- end -}}
  {{- end -}}
  {{- with $c.secretRef -}}
    {{- if not (and (kindIs "map" .) .name) -}}
      {{- fail (printf "%s: connection %q: secretRef must be {name: <Secret name>}" $where $ref) -}}
    {{- end -}}
    {{- $_ := set $out "secretRef" (dict "name" .name) -}}
  {{- end -}}
{{- else -}}
  {{- $conv := index $schema "x-okdp-internal" -}}
  {{- if not $conv -}}
    {{- fail (printf "%s: %q is not in .Values.connections, and the %s contract has no internal naming convention: declare it as an external connection (projects/<project>/connections/%s.yaml)" $where $ref $contract $ref) -}}
  {{- end -}}
  {{- $suffix := "" -}}
  {{- range $k, $tpl := $conv -}}
    {{- if contains "${suffix}" $tpl -}}
      {{- include "okdp.require" (dict "ctx" $ctx "keys" (list "ingress.suffix")) -}}
      {{- $suffix = $ctx.Values.global.okdp.ingress.suffix -}}
    {{- end -}}
    {{- $_ := set $out $k ($tpl | replace "${ref}" $ref | replace "${namespace}" $ctx.Release.Namespace | replace "${suffix}" $suffix) -}}
  {{- end -}}
  {{- $_ := set $out "secretRef" (dict "name" (printf "%s-%s-credentials" $ref $contract)) -}}
{{- end -}}
{{- $fields := omit $out "secretRef" -}}
{{- include "okdp.contract.complete" (dict "schema" $schema "values" $fields "where" (printf "%s (connection %q)" $where $ref)) -}}
{{- $result := merge $fields (pick $out "secretRef") -}}
{{- $_ := set $result "okdp" (dict "ref" $ref "contract" $contract "source" $source) -}}
{{- toYaml $result -}}
{{- end -}}
