{{/* Labels every object in this chart carries. */}}
{{- define "troupe.labels" -}}
app.kubernetes.io/name: troupe
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "troupe.operator.selectorLabels" -}}
app.kubernetes.io/name: troupe
app.kubernetes.io/component: operator
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "troupe.plane.selectorLabels" -}}
app.kubernetes.io/name: troupe
app.kubernetes.io/component: plane
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
