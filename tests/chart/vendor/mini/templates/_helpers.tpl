{{- define "mini.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}{{ .Release.Name }}{{ else }}{{ printf "%s-%s" .Release.Name .Chart.Name }}{{ end }}
{{- end -}}
{{- define "mini.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end -}}
