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

{{/*
The worker container's seccomp profile, which the operator puts on every worker pod.
Refused here rather than in the cluster: a type the kubelet does not know, or a Localhost
profile without its path, is a pod that never starts, said only in an event on each
StatefulSet. The path is relative to the kubelet's seccomp directory and every part of it
starts with a letter or a digit, so it never climbs out of it: the installer mounts the
profile's own directory from the host, and a path with `..` in it would mount another.
*/}}
{{- define "troupe.worker.seccomp.validate" -}}
{{- $seccomp := .Values.worker.seccomp -}}
{{- if not (has $seccomp.type (list "Localhost" "RuntimeDefault" "Unconfined")) }}
{{- fail (printf "worker.seccomp.type is %q: it is Localhost (the chart's profile, which lets bubblewrap make its namespaces), RuntimeDefault (no command runs on a pod) or Unconfined (no filter, for a development cluster)." (toString $seccomp.type)) }}
{{- end }}
{{- if eq $seccomp.type "Localhost" }}
{{- $path := $seccomp.localhostProfile | default "" }}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$" $path) }}
{{- fail (printf "worker.seccomp.localhostProfile is %q: with type Localhost it is the profile's path under the kubelet's seccomp directory, such as troupe/worker.json, each part starting with a letter or a digit." $path) }}
{{- end }}
{{- if $seccomp.install.enabled }}
{{- if not (contains "/" $path) }}
{{- fail (printf "worker.seccomp.localhostProfile is %q, and the installer mounts the profile's own directory from each node, never the kubelet's whole seccomp directory: put it in one, such as troupe/worker.json." $path) }}
{{- end }}
{{- $dir := $seccomp.install.kubeletSeccompDir | default "" }}
{{- if or (not (regexMatch "^/[A-Za-z0-9._/-]*[A-Za-z0-9._-]$" $dir)) (contains ".." $dir) }}
{{- fail (printf "worker.seccomp.install.kubeletSeccompDir is %q: it is the absolute path of the kubelet's seccomp directory on the nodes, /var/lib/kubelet/seccomp unless the kubelet's --root-dir says otherwise." $dir) }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/* Where the installer writes the profile on a node, and the one directory it mounts. */}}
{{- define "troupe.worker.seccomp.hostDir" -}}
{{- printf "%s/%s" (trimSuffix "/" .Values.worker.seccomp.install.kubeletSeccompDir) (dir .Values.worker.seccomp.localhostProfile) -}}
{{- end -}}
