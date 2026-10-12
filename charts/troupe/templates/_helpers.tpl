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

{{/*
The one combination of plane values that installs cleanly and is wrong. The
cluster-unique actors — one Placement per profile, one TeamBudget per team — are
registered with `:global`, and `:global` spans an Erlang cluster. Two replicas with
distribution off are not two replicas of one plane but two planes, each placing
sessions and reserving budget as if it were alone. Nothing at runtime notices; the
symptom is sessions placed twice. So the chart refuses rather than the operator
debugging it.
*/}}
{{/*
The browser origins every worker pod admits, as one comma-separated value:
`operator.workerAllowedOrigins`, and the plane's own origin when this chart serves the GUI
there, since that page attaches to the pods too. Nothing else; the desktop app's origin
the worker admits by itself. A page whose origin is not here gets no socket.
*/}}
{{- define "troupe.operator.workerOrigins" -}}
{{- $origins := .Values.operator.workerAllowedOrigins | default list -}}
{{- if and .Values.gui.enabled .Values.plane.enabled -}}
{{- $url := urlParse (.Values.plane.baseUrl | default (printf "https://%s" .Values.plane.host)) -}}
{{- $origins = append $origins (lower (printf "%s://%s" $url.scheme $url.host)) -}}
{{- end -}}
{{- join "," ($origins | uniq) -}}
{{- end -}}

{{- define "troupe.plane.validate" -}}
{{- if and (gt (int .Values.plane.replicas) 1) (ne .Values.plane.distribution "name") }}
{{- fail (printf "plane.replicas is %d but plane.distribution is %q: replicas that do not form an Erlang cluster each place sessions as if alone. Set plane.distribution to \"name\", or plane.replicas to 1." (int .Values.plane.replicas) .Values.plane.distribution) }}
{{- end }}
{{- end -}}
