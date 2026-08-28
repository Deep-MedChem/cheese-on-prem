{{/*
Chart-wide labels (shared across all components).
*/}}
{{- define "cheese.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "cheese.labels" -}}
helm.sh/chart: {{ include "cheese.chart" . }}
app.kubernetes.io/name: cheese
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: cheese
{{- end }}

{{/*
Per-component labels and selectors. Pass (list $ "<component>").
Component name disambiguates pods/services across the chart and is the only
distinguishing selector label between components (`name=cheese` is shared).
*/}}
{{- define "cheese.componentLabels" -}}
{{- $root := index . 0 -}}
{{- $component := index . 1 -}}
{{ include "cheese.labels" $root }}
app.kubernetes.io/component: {{ $component }}
{{- end -}}

{{- define "cheese.componentSelectorLabels" -}}
{{- $root := index . 0 -}}
{{- $component := index . 1 -}}
app.kubernetes.io/name: cheese
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/component: {{ $component }}
{{- end -}}

{{/*
Image reference. Takes an image block — e.g. `.Values.database.image` — and
returns "<repository>:<tag>" from the selected source.
*/}}
{{- define "cheese.image" -}}
{{- $src := .source -}}
{{- $img := index . $src -}}
{{- printf "%s:%s" $img.repository (default "latest" $img.tag) -}}
{{- end -}}

{{- define "cheese.imagePullPolicy" -}}
{{- $src := .source -}}
{{- $img := index . $src -}}
{{- default "IfNotPresent" $img.pullPolicy -}}
{{- end -}}

{{/*
Image pull secrets block: emits "imagePullSecrets:" only when source = acr.
Pass an image block (e.g. `.Values.orchestrator.image`).
*/}}
{{- define "cheese.imagePullSecrets" -}}
{{- if eq .source "acr" }}
imagePullSecrets:
  - name: {{ default "cheese-acr-pull" .acr.pullSecret }}
{{- end }}
{{- end -}}

{{/*
Secret name resolver for the external-secret pattern. Pass (list <existingSecret> <chartDefaultName>).
Returns the operator-provided existingSecret when set (client manages it externally —
Vault / ESO / SealedSecrets / pre-created kubectl secret), else the chart's own
rendered secret name (local self-contained path). The chart's Secret template is
skipped whenever existingSecret is set, so keys must match the documented set.
*/}}
{{- define "cheese.secretName" -}}
{{- $existing := index . 0 -}}
{{- $default := index . 1 -}}
{{- if $existing }}{{ $existing }}{{ else }}{{ $default }}{{ end -}}
{{- end -}}

{{/* Resolved name of the supabase secret (existingSecret-aware). Pass root context. */}}
{{- define "cheese.supabaseSecretName" -}}
{{- include "cheese.secretName" (list .Values.supabase.secret.existingSecret "cheese-supabase") -}}
{{- end -}}

{{/* Browser/external Supabase origin: supabase.publicUrl, else the in-cluster gateway. Pass root. */}}
{{- define "cheese.supabasePublicUrl" -}}
{{- $s := .Values.supabase -}}
{{- if $s.publicUrl }}{{ $s.publicUrl }}{{ else }}{{ printf "http://supabase-gateway.cheese.svc.cluster.local:%v" $s.gateway.port }}{{ end -}}
{{- end -}}

{{/*
Pod anti-affinity preset. Pass (list $ "<component>" <componentValues>). The
<componentValues> arg supplies .podAntiAffinityPreset.
*/}}
{{- define "cheese.affinityPreset" -}}
{{- $root := index . 0 -}}
{{- $component := index . 1 -}}
{{- $cfg := index . 2 -}}
podAntiAffinity:
  {{- if eq $cfg.podAntiAffinityPreset.type "soft" }}
  preferredDuringSchedulingIgnoredDuringExecution:
  - podAffinityTerm:
      labelSelector:
        matchLabels:
          {{- include "cheese.componentSelectorLabels" (list $root $component) | nindent 10 }}
      topologyKey: {{ $cfg.podAntiAffinityPreset.topologyKey }}
    weight: 1
  {{- else if eq $cfg.podAntiAffinityPreset.type "hard" }}
  requiredDuringSchedulingIgnoredDuringExecution:
  - labelSelector:
      matchLabels:
          {{- include "cheese.componentSelectorLabels" (list $root $component) | nindent 10 }}
    topologyKey: {{ $cfg.podAntiAffinityPreset.topologyKey }}
  {{- else }} {}
  {{- end }}
{{- end -}}