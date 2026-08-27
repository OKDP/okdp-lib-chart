{{/* The okdp.instance.* hooks, overridden as a service chart does. */}}
{{- define "okdp.instance.url" -}}
{{- if .Values.test.ui }}{{ include "okdp.url" (dict "ctx" . "name" "mini") }}{{ end -}}
{{- end -}}

{{- define "okdp.instance.usage" -}}
Mini is reachable at {{ include "okdp.url" (dict "ctx" . "name" "mini") }}.
{{- end -}}

{{- define "okdp.instance.outputs" -}}
{{- if .Values.test.provide.hive }}
{{ include "okdp.contract.hive.provide" (dict "ctx" . "values" (dict "thriftUri" (printf "thrift://%s-hive-metastore.%s.svc:9083" .Release.Name .Release.Namespace))) }}
{{- end }}
{{- if .Values.test.provide.trino }}
{{ include "okdp.contract.trino.provide" (dict "ctx" . "values" (dict
     "url" (printf "https://trino-%s.%s" .Release.Namespace .Values.global.okdp.ingress.suffix)
     "uri" (printf "trino://trino@trino-%s.%s:443" .Release.Namespace .Values.global.okdp.ingress.suffix)
     "internalUri" (printf "trino://trino@%s-trino.%s.svc:8080" .Release.Name .Release.Namespace)
     "catalogs" (list "tpch" "bronze"))) }}
{{- end }}
{{- if .Values.test.provide.database }}
{{ include "okdp.contract.database-server.provide" (dict "ctx" . "name" (printf "%s-app" .Release.Name)
     "values" (dict "host" (printf "%s-rw.%s.svc" .Release.Name .Release.Namespace) "dbName" "app")
     "secret" (dict "generate" (list (dict "key" "password" "length" 24)) "stringData" (dict "username" "app"))) }}
{{- end }}
{{- if .Values.test.provide.s3 }}
{{ include "okdp.contract.s3.provide" (dict "ctx" . "name" (printf "%s-store" .Release.Name)
     "values" (dict "apiUrl" "http://store.example:8333")
     "secret" (dict "stringData" (dict "accessKey" "a" "secretKey" "b"))) }}
{{- end }}
{{- if .Values.test.provide.bad }}
{{ include "okdp.contract.hive.provide" (dict "ctx" . "values" (dict "thriftUri" "thrift://elsewhere:9083")) }}
{{- end }}
{{- end -}}
