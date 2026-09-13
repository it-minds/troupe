{{- define "troupe-gui.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "troupe-gui.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "troupe-gui.labels" -}}
app.kubernetes.io/name: {{ include "troupe-gui.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: gui
{{- end -}}

{{- define "troupe-gui.selectorLabels" -}}
app.kubernetes.io/name: {{ include "troupe-gui.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- /* The base path without a trailing slash: "/app", or "" at the root. */ -}}
{{- define "troupe-gui.base" -}}
{{- $base := default "/" .Values.basePath -}}
{{- if eq $base "/" -}}{{- "" -}}{{- else -}}{{- trimSuffix "/" $base -}}{{- end -}}
{{- end -}}
