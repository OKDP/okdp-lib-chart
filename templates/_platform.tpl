{{/*
Copyright 2026 The OKDP Authors.
Licensed under the Apache License, Version 2.0.

Platform values: global.okdp, written once in platform/platform-values.yaml.
Keys are the former KuboCD platform Context keys, same names.
*/}}

{{/*
Calling convention: helpers documented as taking `$` accept either the root
context or a dict carrying it under "ctx" (plus their own options). Helpers
that need options always take a dict with "ctx".
*/}}

{{/*
okdp.platform.get: value at a dotted path under global.okdp, as YAML
{"v": <value>} so its type survives the include. Missing -> {"v": null}.
  {{ (include "okdp.platform.get" (dict "ctx" $ "path" "ingress.suffix") | fromYaml).v }}
*/}}
{{- define "okdp.platform.get" -}}
{{- $cur := ((.ctx.Values.global | default dict).okdp | default dict) -}}
{{- $found := true -}}
{{- range $seg := splitList "." .path -}}
  {{- if and $found (kindIs "map" $cur) (hasKey $cur $seg) -}}
    {{- $cur = index $cur $seg -}}
  {{- else -}}
    {{- $found = false -}}
  {{- end -}}
{{- end -}}
{{- if $found }}{{ toYaml (dict "v" $cur) }}{{ else }}v: null{{ end -}}
{{- end -}}

{{/*
okdp.require: fail with an actionable message unless every dotted path of
"keys" is set (non-empty) under global.okdp.
  {{- include "okdp.require" (dict "ctx" $ "keys" (list "ingress.suffix" "oidc.issuerUri")) }}
Renders nothing.
*/}}
{{- define "okdp.require" -}}
{{- $ctx := .ctx -}}
{{- range $key := .keys -}}
  {{- $v := (include "okdp.platform.get" (dict "ctx" $ctx "path" $key) | fromYaml).v -}}
  {{- if or (kindIs "invalid" $v) (and (kindIs "string" $v) (eq $v "")) -}}
    {{- fail (printf "%s: global.okdp.%s is required. It is a platform value: set it in platform/platform-values.yaml (the first values layer)." $ctx.Chart.Name $key) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
okdp.oidc: global.okdp.oidc with defaults applied and the booleans the former
KuboCD `enabled:` expressions computed, as YAML (use fromYaml):
  enabled             default true
  scope               default "openid profile email groups"
  clientProvisioning  default "existing" (existing | dcr | kubauth)
  dcr.enabled         clientProvisioning == "dcr"
  kubauth.enabled     clientProvisioning == "kubauth"
  existing            clientProvisioning == "existing"
  {{- $oidc := include "okdp.oidc" $ | fromYaml }}
*/}}
{{- define "okdp.oidc" -}}
{{- $ctx := . -}}{{- if and (kindIs "map" .) (hasKey . "ctx") }}{{ $ctx = .ctx }}{{ end -}}
{{- $o := deepCopy (((($ctx.Values.global | default dict).okdp | default dict).oidc) | default dict) -}}
{{- if not (hasKey $o "enabled") }}{{ $_ := set $o "enabled" true }}{{ end -}}
{{- if not $o.scope }}{{ $_ := set $o "scope" "openid profile email groups" }}{{ end -}}
{{- if not $o.clientProvisioning }}{{ $_ := set $o "clientProvisioning" "existing" }}{{ end -}}
{{- $mode := $o.clientProvisioning -}}
{{- if not (has $mode (list "existing" "dcr" "kubauth")) -}}
  {{- fail (printf "global.okdp.oidc.clientProvisioning %q is not one of existing, dcr, kubauth" $mode) -}}
{{- end -}}
{{- $dcr := deepCopy ($o.dcr | default dict) -}}
{{- $_ := set $dcr "enabled" (and $o.enabled (eq $mode "dcr")) -}}
{{- $_ := set $o "dcr" $dcr -}}
{{- $kubauth := deepCopy ($o.kubauth | default dict) -}}
{{- $_ := set $kubauth "enabled" (and $o.enabled (eq $mode "kubauth")) -}}
{{- $_ := set $o "kubauth" $kubauth -}}
{{- $_ := set $o "existing" (and $o.enabled (eq $mode "existing")) -}}
{{- toYaml $o -}}
{{- end -}}

{{/*
okdp.proxy.env: the platform proxy as a YAML map of environment variables
(HTTP_PROXY, HTTPS_PROXY, NO_PROXY), empty entries left out. "{}" when unset.
  extraEnv: {{- include "okdp.proxy.env" $ | nindent 2 }}
*/}}
{{- define "okdp.proxy.env" -}}
{{- $ctx := . -}}{{- if and (kindIs "map" .) (hasKey . "ctx") }}{{ $ctx = .ctx }}{{ end -}}
{{- $p := ((($ctx.Values.global | default dict).okdp | default dict).proxy) | default dict -}}
{{- $env := dict -}}
{{- with $p.httpProxy }}{{ $_ := set $env "HTTP_PROXY" . }}{{ end -}}
{{- with $p.httpsProxy }}{{ $_ := set $env "HTTPS_PROXY" . }}{{ end -}}
{{- with $p.noProxy }}{{ $_ := set $env "NO_PROXY" . }}{{ end -}}
{{- toYaml $env -}}
{{- end -}}

{{/*
okdp.proxy.envList: same as okdp.proxy.env, as a Kubernetes env list
([{name, value}]). "[]" when unset.
*/}}
{{- define "okdp.proxy.envList" -}}
{{- $env := include "okdp.proxy.env" . | fromYaml -}}
{{- $list := list -}}
{{- range $k := keys $env | sortAlpha -}}
  {{- $list = append $list (dict "name" $k "value" (index $env $k)) -}}
{{- end -}}
{{- toYaml $list -}}
{{- end -}}
