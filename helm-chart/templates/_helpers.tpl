{{/*
Nombre de la Chart (o nameOverride).
*/}}
{{- define "shape-game.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Nombre base de los recursos. Si la release ya contiene el nombre de la Chart
(ej: "shape-game", "shape-game-dev") se usa tal cual; si no, "<release>-shape-game".
*/}}
{{- define "shape-game.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Etiquetas comunes a todos los recursos.
*/}}
{{- define "shape-game.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "shape-game.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: shape-game
{{- end }}

{{/*
Selector de los pods de la app (sin el color). Se mantiene la etiqueta "app:
shape-game" porque la usan Prometheus (service discovery) y los scripts.
*/}}
{{- define "shape-game.appSelectorLabels" -}}
app: shape-game
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: app
{{- end }}

{{/*
Selector de los pods de Redis.
*/}}
{{- define "shape-game.redisSelectorLabels" -}}
app.kubernetes.io/name: {{ include "shape-game.name" . }}-redis
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: redis
{{- end }}

{{/*
Nombres de los recursos de Redis.
*/}}
{{- define "shape-game.redisName" -}}
{{- printf "%s-redis" (include "shape-game.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
securityContext de contenedor endurecido (común a todos los contenedores).
*/}}
{{- define "shape-game.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}
