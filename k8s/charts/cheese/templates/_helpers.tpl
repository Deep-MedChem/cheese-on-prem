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
Image reference. Returns "<repository>:<tag>" for the selected source.

Call it with the root context so `source: ecr` can compose paths from the shared
`onprem` settings:

    {{ include "cheese.image" (list $ .Values.database.image) }}

A bare image block still works (`include "cheese.image" $db.image`) for callers
that predate this, but then `source: ecr` has nothing to compose from and fails
with an explicit message rather than rendering a half-built reference.

Sources:
  local — an image already on the node (kind dev). Used verbatim.
  ecr   — DeepMedChem's registry. Composed as
          <onprem.registry>/on-prem/<ecr.image>/<onprem.customer>:<tag>
          so the customer slug lives in ONE place rather than in every
          component. Per-component ecr.tag wins over onprem.imageTag.
  acr   — RETIRED. The Azure registry account was shut down in July 2026 and is
          unreachable, so this fails at render time. Left in place only so an
          existing values.yaml gets a message that says what to do instead of an
          ImagePullBackOff nobody can explain.
*/}}
{{- define "cheese._imageCtx" -}}
{{- /* Normalise both call styles into a dict of root + image block. */ -}}
{{- if kindIs "slice" . -}}
{{- dict "root" (index . 0) "img" (index . 1) | toYaml -}}
{{- else -}}
{{- dict "root" nil "img" . | toYaml -}}
{{- end -}}
{{- end -}}

{{- define "cheese.image" -}}
{{- $ctx := fromYaml (include "cheese._imageCtx" .) -}}
{{- $image := $ctx.img -}}
{{- $src := $image.source -}}
{{- if eq $src "acr" -}}
{{- fail "image.source: acr is retired — the Azure registry account was shut down in July 2026 and cannot be pulled from. Use source: ecr and set onprem.customer (see k8s/README.md, \"Images\")." -}}
{{- end -}}
{{- $sel := index $image $src -}}
{{- if eq $src "ecr" -}}
{{- $root := $ctx.root -}}
{{- if not $root -}}
{{- fail "source: ecr needs the root context — call this helper as (list $ <image block>), not with the image block alone." -}}
{{- end -}}
{{- $op := $root.Values.onprem -}}
{{- if not $op.customer -}}
{{- fail "source: ecr requires onprem.customer — the per-customer segment of on-prem/<image>/<customer>. DeepMedChem issues you this slug together with your access key." -}}
{{- end -}}
{{- if not $sel.image -}}
{{- fail (printf "source: ecr requires ecr.image (the <image> in on-prem/<image>/<customer>) on this component") -}}
{{- end -}}
{{- $tag := $sel.tag | default $op.imageTag | default "latest" -}}
{{- printf "%s/on-prem/%s/%s:%s" (trimSuffix "/" $op.registry) $sel.image $op.customer $tag -}}
{{- else -}}
{{- printf "%s:%s" $sel.repository (default "latest" $sel.tag) -}}
{{- end -}}
{{- end -}}

{{- define "cheese.imagePullPolicy" -}}
{{- $ctx := fromYaml (include "cheese._imageCtx" .) -}}
{{- $image := $ctx.img -}}
{{- $sel := index $image $image.source -}}
{{- default "IfNotPresent" $sel.pullPolicy -}}
{{- end -}}

{{/*
Image pull secrets block: emits "imagePullSecrets:" only when source = acr.
Pass an image block (e.g. `.Values.orchestrator.image`).
*/}}
{{- define "cheese.imagePullSecrets" -}}
{{- $ctx := fromYaml (include "cheese._imageCtx" .) -}}
{{- $image := $ctx.img -}}
{{- if eq $image.source "ecr" }}
{{- $root := $ctx.root }}
{{- $name := $image.ecr.pullSecret | default (and $root $root.Values.onprem.pullSecret) | default "cheese-ecr-pull" }}
imagePullSecrets:
  - name: {{ $name }}
{{- else if eq $image.source "acr" }}
imagePullSecrets:
  - name: {{ default "cheese-acr-pull" $image.acr.pullSecret }}
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
{{/*
--- licence agent (v1 licensing) ------------------------------------------
Resolved name of the licence-agent secret holding `licenseKey` (existingSecret-aware).
Pass root context.
*/}}
{{- define "cheese.licenseAgentSecretName" -}}
{{- include "cheese.secretName" (list .Values.licenseAgent.secret.existingSecret "cheese-license-key") -}}
{{- end -}}

{{/* ServiceAccount the licence agent runs as. Pass root context. */}}
{{- define "cheese.licenseAgentServiceAccountName" -}}
{{- $sa := .Values.licenseAgent.serviceAccount -}}
{{- if $sa.name }}{{ $sa.name }}{{ else }}cheese-license-agent{{ end -}}
{{- end -}}

{{/*
Licence-file location the agent WRITES, as a path relative to data.mountPath.
licenseAgent.licenseFile wins; otherwise it is inherited from the readers
(database, then orchestrator) so writer and readers cannot drift apart.
Leading "/" is stripped: the product images resolve CHEESE_LICENSE_FILE as
"<DATA_ROOT>/<value lstripped of '/'>", so an "absolute" value is in fact
relative to the mount too. Pass root context.
*/}}
{{- define "cheese.licenseFileRelPath" -}}
{{- $v := .Values.licenseAgent.licenseFile -}}
{{- if not $v }}{{- $v = .Values.database.secret.cheeseLicenseFile -}}{{- end -}}
{{- if not $v }}{{- $v = .Values.orchestrator.secret.cheeseLicenseFile -}}{{- end -}}
{{- if not $v }}{{- fail "licenseAgent.enabled=true but no licence filename is set: set licenseAgent.licenseFile (or database.secret.cheeseLicenseFile)" -}}{{- end -}}
{{- trimPrefix "/" $v -}}
{{- end -}}

{{/* Absolute in-container path of the licence file the agent writes. Pass root context. */}}
{{- define "cheese.licenseFileAbsPath" -}}
{{- printf "%s/%s" (trimSuffix "/" .Values.data.mountPath) (include "cheese.licenseFileRelPath" .) -}}
{{- end -}}
