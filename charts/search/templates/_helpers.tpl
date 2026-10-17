{{- define "search.labels" -}}
app.kubernetes.io/part-of: search
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "search.image" -}}
{{ .repository }}:{{ .tag }}
{{- end }}
