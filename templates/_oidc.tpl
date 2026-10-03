{{/*
Copyright 2026 The OKDP Authors.
Licensed under the Apache License, Version 2.0.

The OAuth client a service signs users in with, in both modes of
global.okdp.oidc.clientProvisioning (see okdp.oidc).
*/}}

{{/*
okdp.oidc.clientSecret: the Secret holding the service's OAuth client (keys
client_id and client_secret):
  existing  creds-<release>-oauth2, created beforehand (the platform convention)
  dcr       <release>-<namespace>-dcr, written by the oidc-dcr Job (okdp.oidc.dcr)
Takes `$`.
  {{- $secret := include "okdp.oidc.clientSecret" $ }}
*/}}
{{- define "okdp.oidc.clientSecret" -}}
{{- $ctx := . -}}{{- if and (kindIs "map" .) (hasKey . "ctx") }}{{ $ctx = .ctx }}{{ end -}}
{{- if (include "okdp.oidc" $ctx | fromYaml).dcr.enabled -}}
{{- printf "%s-%s-dcr" $ctx.Release.Name $ctx.Release.Namespace -}}
{{- else -}}
{{- printf "creds-%s-oauth2" $ctx.Release.Name -}}
{{- end -}}
{{- end -}}

{{/*
okdp.oidc.dcr: in dcr mode, the oidc-dcr Job that registers the service's
OAuth client by anonymous dynamic client registration and writes it to a
Secret (okdp.vendor.oidcDcr); nothing in existing mode.

  {{ include "okdp.oidc.dcr" (dict "ctx" $
       "redirectUris" (list (printf "https://%s/oauth2/callback" $host))
       "grantTypes" (list "authorization_code" "refresh_token")) }}

Arguments:
  ctx           the root context ($).
  grantTypes    the OAuth grant types (list, required).
  redirectUris  list; none for a client without user sign-in.
  scope         space separated, default global.okdp.oidc.scope. openid is
                dropped: it is not a Keycloak client scope, Keycloak refuses it.
  clientName    default <release>-<namespace>.
  secret        the Secret the Job writes, default <release>-<namespace>-dcr
                (okdp.oidc.clientSecret in dcr mode).
  public        true: a public client (token_endpoint_auth_method none), only
                client_id is written to the Secret.
  request       map merged over the registration request (e.g. logo_uri).
  caSecret      the CA bundle Secret the Job trusts, default certs-bundle.
  name          the Job's objects, default <release>-oidc-dcr: give one to a
                second client of the same release (see okdp.vendor.oidcDcr).

Fails unless global.okdp.oidc.dcr.authMethod is anonymous and
global.okdp.oidc.dcr.registrationUrl is set.
*/}}
{{- define "okdp.oidc.dcr" -}}
{{- if (include "okdp.oidc" .ctx | fromYaml).dcr.enabled -}}
{{- include "okdp.vendor.oidcDcr" (dict "ctx" .ctx "values" (include "okdp.oidc.dcrValues" . | fromYaml) "name" .name) -}}
{{- end -}}
{{- end -}}

{{/* okdp.oidc.dcrValues: internal to okdp.oidc.dcr. The oidc-dcr values, as YAML. Same arguments. */}}
{{- define "okdp.oidc.dcrValues" -}}
{{- $ctx := .ctx -}}
{{- $oidc := include "okdp.oidc" $ctx | fromYaml -}}
{{- if ne (toString ($oidc.dcr.authMethod | default "")) "anonymous" -}}
  {{- fail (printf "%s: global.okdp.oidc.dcr.authMethod %q is not supported: this chart registers anonymously" $ctx.Chart.Name (toString ($oidc.dcr.authMethod | default ""))) -}}
{{- end -}}
{{- include "okdp.require" (dict "ctx" $ctx "keys" (list "oidc.dcr.registrationUrl")) -}}
{{- $request := dict
      "application_type" "web"
      "client_name" (.clientName | default (printf "%s-%s" $ctx.Release.Name $ctx.Release.Namespace))
      "grant_types" (required (printf "%s: okdp.oidc.dcr: grantTypes is required" $ctx.Chart.Name) .grantTypes)
      "scope" (without (splitList " " (.scope | default $oidc.scope)) "openid" | join " ") -}}
{{- with .redirectUris }}{{ $_ := set $request "redirect_uris" . }}{{ end -}}
{{- $keys := dict "client_id" ".client_id" "client_secret" ".client_secret" -}}
{{- if .public -}}
  {{- $_ := set $request "token_endpoint_auth_method" "none" -}}
  {{- $keys = dict "client_id" ".client_id" -}}
{{- end -}}
{{- $request = mergeOverwrite $request (deepCopy (.request | default dict)) -}}
{{- toYaml (dict
      "ttl_seconds" 30
      "registration_url" $oidc.dcr.registrationUrl
      "request" $request
      "tls" (dict "insecure" false "certificate" (.caSecret | default "certs-bundle"))
      "secret" (.secret | default (printf "%s-%s-dcr" $ctx.Release.Name $ctx.Release.Namespace))
      "mapping" (dict "use_default" false "key_mapping" $keys)) -}}
{{- end -}}
