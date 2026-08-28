{{/*
Common template helpers
*/}}

{{ define "bot-service.name" -}}
{{ default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{ end -}}

{{ define "bot-service.fullname" -}}
{{ if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "bot-service.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "bot-service.labels" -}}
app.kubernetes.io/name: {{ include "bot-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "bot-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bot-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "bot-service.componentName" -}}
{{- $root := index . 0 -}}
{{- $component := index . 1 -}}
{{- printf "%s-%s" (include "bot-service.fullname" $root) $component | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "bot-service.redisUrl" -}}
{{- if .Values.redis.enabled -}}
{{- printf "redis://%s.%s.svc.%s:%d/0" (include "bot-service.componentName" (list . "redis")) .Release.Namespace .Values.global.clusterDomain (.Values.redis.service.port | int) -}}
{{- else -}}
{{- required "redisConfig.url is required when redis.enabled=false" .Values.redisConfig.url -}}
{{- end -}}
{{- end -}}

{{- define "bot-service.redisHost" -}}
{{- if .Values.redis.enabled -}}
{{- printf "%s.%s.svc.%s" (include "bot-service.componentName" (list . "redis")) .Release.Namespace .Values.global.clusterDomain -}}
{{- else -}}
{{- required "redisConfig.host is required when redis.enabled=false" .Values.redisConfig.host -}}
{{- end -}}
{{- end -}}

{{- define "bot-service.redisPort" -}}
{{- if .Values.redis.enabled -}}
{{- .Values.redis.service.port | int -}}
{{- else -}}
{{- required "redisConfig.port is required when redis.enabled=false" .Values.redisConfig.port -}}
{{- end -}}
{{- end -}}

{{- define "bot-service.dbHost" -}}
{{- if .Values.postgres.enabled -}}
{{- include "bot-service.componentName" (list . "postgres") -}}
{{- else -}}
{{- required "database.host is required when postgres.enabled=false" .Values.database.host -}}
{{- end -}}
{{- end -}}

{{- define "bot-service.adminTokenSecretName" -}}
{{- if .Values.secrets.existingSecretName -}}
{{- .Values.secrets.existingSecretName -}}
{{- else -}}
{{- include "bot-service.componentName" (list . "secrets") -}}
{{- end -}}
{{- end -}}

{{/* The on-demand bot image the runtime spawns (BROWSER_IMAGE). The bot is published, never built by
this chart. runtime.browserImage is the explicit value; global.imageTag (set) pins the standard repo. */}}
{{- define "bot-service.botImage" -}}
{{- if .Values.runtime.browserImage -}}
{{- .Values.runtime.browserImage -}}
{{- else if .Values.global.imageTag -}}
{{- printf "bot-service-lite/bot-service-bot:%s" .Values.global.imageTag -}}
{{- else -}}
bot-service-lite/bot-service-bot:dev
{{- end -}}
{{- end -}}

{{- define "bot-service.postgresCredentialsSecretName" -}}
{{- if .Values.postgres.enabled -}}
{{- .Values.postgres.credentialsSecretName | default "postgres-credentials" -}}
{{- else -}}
{{- required "postgres.credentialsSecretName must name a pre-existing Secret when postgres.enabled=false (keys: POSTGRES_PASSWORD, POSTGRES_USER, POSTGRES_DB)" .Values.postgres.credentialsSecretName -}}
{{- end -}}
{{- end -}}

{{/*
bot-service.topologySpreadConstraints — render pod topology spread constraints for a component.

Call:  include "bot-service.topologySpreadConstraints" (list $root $componentValues "component-name")
  - $root           = the template root context (.)
  - $componentValues = that component's values map (e.g. .Values.gateway)
  - "component-name" = the value of its app.kubernetes.io/component label (e.g. "gateway")

Per-component `.topologySpreadConstraints` wins over `global.topologySpreadConstraints`
(same override shape as replicaCount/resources). Each constraint that omits `labelSelector`
gets the component's OWN pod selector injected — name + instance + component — so the default
meaning is "spread THIS component's replicas across the topology". Renders NOTHING when neither
global nor per-component constraints are set (empty default is byte-identical to a chart without
the field).
*/}}
{{- define "bot-service.topologySpreadConstraints" -}}
{{- $root := index . 0 -}}
{{- $componentValues := index . 1 -}}
{{- $component := index . 2 -}}
{{- $constraints := $componentValues.topologySpreadConstraints | default $root.Values.global.topologySpreadConstraints -}}
{{- if $constraints -}}
{{- $selector := dict "matchLabels" (dict "app.kubernetes.io/name" (include "bot-service.name" $root) "app.kubernetes.io/instance" $root.Release.Name "app.kubernetes.io/component" $component) -}}
topologySpreadConstraints:
{{- range $constraints }}
{{- if hasKey . "labelSelector" }}
  -{{ toYaml . | nindent 4 }}
{{- else }}
  -{{ toYaml (merge (deepCopy .) (dict "labelSelector" $selector)) | nindent 4 }}
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}

{{- define "bot-service.deploymentStrategy" -}}
{{/*
Zero-downtime rolling update. maxSurge: 1 / maxUnavailable: 0 — the NEW pod is created first;
helm waits until it's Ready before killing the OLD. Combine with --atomic --wait on the helm
upgrade call so a failed image pull auto-rolls-back without ever exposing an outage. Works on
replicaCount=1 (1 old -> 1 old + 1 new -> 1 new) and replicaCount>1 (rolling one extra at a time).
*/}}
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1
    maxUnavailable: 0
{{- end -}}

{{/*
Redis durability paired invariant: AOF (appendonly + appendfsync) is the per-write durability
mechanism. `stop-writes-on-bgsave-error: no` allows writes to continue when the snapshot mechanism
fails, which is only non-blocking when AOF is on. Setting `stop-writes-on-bgsave-error: yes`
WITHOUT `appendonly: yes` creates a write-loss window. Refuse to render that combination.
*/}}
{{- define "bot-service.validateRedisDurability" -}}
{{- $aof := .Values.redis.durability.appendonly | default "yes" -}}
{{- $bgsaveBlocks := .Values.redis.durability.stopWritesOnBgsaveError | default "no" -}}
{{- if and (eq $bgsaveBlocks "yes") (ne $aof "yes") -}}
{{- required "INVALID redis.durability config: stopWritesOnBgsaveError=yes requires appendonly=yes (paired AOF + BGSAVE durability invariant). Without AOF, blocking writes on BGSAVE failure means writes that arrive while BGSAVE is failing have no durable record anywhere." "" -}}
{{- end -}}
{{- end -}}
