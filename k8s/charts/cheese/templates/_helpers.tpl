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
that predate this, but then `source: ecr` cannot read onprem.imageTag and fails
with an explicit message rather than rendering a half-built reference.

Sources:
  local — an image already on the node (kind dev). Used verbatim.
  ecr   — DeepMedChem's registry. ecr.repository is the full path; the tag
          comes from onprem.imageTag unless the component sets its own ecr.tag.
  acr   — GONE. The Azure registry was retired and its values blocks are
          deleted. Setting it fails at render, naming the replacement, so an
          un-migrated values.yaml can't quietly render an unpullable path.
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
{{- fail "image.source: acr is gone — the Azure registry was retired and the acr block has been removed from values.yaml. Use source: ecr (see k8s/README.md, \"Images\")." -}}
{{- end -}}
{{- $sel := index $image $src -}}
{{- if eq $src "ecr" -}}
{{- $root := $ctx.root -}}
{{- if not $root -}}
{{- fail "source: ecr needs the root context for onprem.imageTag — call this helper as (list $ <image block>), not with the image block alone." -}}
{{- end -}}
{{- $op := $root.Values.onprem -}}
{{- if not $sel.repository -}}
{{- fail (printf "source: ecr requires ecr.repository (the full image path) on this component") -}}
{{- end -}}
{{- $tag := $sel.tag | default $op.imageTag | default "latest" -}}
{{- printf "%s:%s" $sel.repository $tag -}}
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
Image pull secrets block: emits "imagePullSecrets:" only when source = ecr.
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
{{- define "cheese.licensingAgentSecretName" -}}
{{- include "cheese.secretName" (list .Values.licensingAgent.secret.existingSecret "dmch-license-key") -}}
{{- end -}}

{{/* ServiceAccount the licence agent runs as. Pass root context. */}}
{{- define "cheese.licensingAgentServiceAccountName" -}}
{{- $sa := .Values.licensingAgent.serviceAccount -}}
{{- if $sa.name }}{{ $sa.name }}{{ else }}dmch-licensing-agent{{ end -}}
{{- end -}}

{{/*
Licence-file location the agent WRITES, as a path relative to data.mountPath.
licensingAgent.licenseFile wins; otherwise it is inherited from the readers
(database, then orchestrator) so writer and readers cannot drift apart.
Leading "/" is stripped: the product images resolve CHEESE_LICENSE_FILE as
"<DATA_ROOT>/<value lstripped of '/'>", so an "absolute" value is in fact
relative to the mount too. Pass root context.
*/}}
{{- define "cheese.licenseFileRelPath" -}}
{{- $v := .Values.licensingAgent.licenseFile -}}
{{- if not $v }}{{- $v = .Values.database.secret.cheeseLicenseFile -}}{{- end -}}
{{- if not $v }}{{- $v = .Values.orchestrator.secret.cheeseLicenseFile -}}{{- end -}}
{{- if not $v }}{{- fail "licensingAgent.enabled=true but no licence filename is set: set licensingAgent.licenseFile (or database.secret.cheeseLicenseFile)" -}}{{- end -}}
{{- trimPrefix "/" $v -}}
{{- end -}}

{{/* Absolute in-container path of the licence file the agent writes. Pass root context. */}}
{{- define "cheese.licenseFileAbsPath" -}}
{{- printf "%s/%s" (trimSuffix "/" .Values.data.mountPath) (include "cheese.licenseFileRelPath" .) -}}
{{- end -}}

{{/*
Release-prefixed object name. The chart otherwise hardcodes resource names, but
the data-sync Job is per-release (two releases in one namespace would collide on
a bare name), so it gets a prefixed one.
*/}}
{{- define "cheese.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Absolute in-container directory the data-sync Job writes database folders into.

It MUST land where the database expects them, or the sync silently populates a
path nothing reads. The database resolves each entry as
    OUTPUT_DIRECTORIES[name] = <database.databasesRoot>/<output_directory>
and the products then resolve that against ${DATA_ROOT:-/data}, stripping any
leading slash — which is why an absolute-looking databasesRoot such as
`/mnt/DATA/cheese-databases` really becomes `/data/mnt/DATA/cheese-databases`
inside the container. This helper reproduces that join exactly rather than
guessing, so writer and readers cannot disagree.

`dataSync.targetDir` overrides it outright for layouts this does not cover.
*/}}
{{- define "cheese.dataSyncRoot" -}}
{{- $ds := .Values.dataSync -}}
{{- if $ds.targetDir -}}
{{- $ds.targetDir -}}
{{- else -}}
{{- $mount := .Values.data.mountPath | trimSuffix "/" -}}
{{- $dbRoot := .Values.database.databasesRoot | default "" | trimPrefix "/" | trimSuffix "/" -}}
{{- if $dbRoot -}}
{{- printf "%s/%s" $mount $dbRoot -}}
{{- else -}}
{{- $mount -}}
{{- end -}}
{{- end -}}
{{- end -}}
