{{/*
Platform abstraction — maps deployment.target (local | aws) to the
storage class and ingress class to use, so switching environments is a single
values change rather than hand-edited overlays.

  local : kind / bare-metal dev. hostPath PV (storageClass cheese-local-manual),
          nginx ingress.
  aws   : SCAFFOLD ONLY (no AWS sources/images yet). gp3 (RWO) or efs-sc (RWX)
          storage, alb ingress. Untested placeholder seam.

azure is deprecated and intentionally unsupported.

An explicit deployment.storage.className / deployment.ingress.className always
wins over the target default.
*/}}

{{- define "cheese.storageClass" -}}
{{- $d := .Values.deployment -}}
{{- if $d.storage.className -}}
{{- $d.storage.className -}}
{{- else if eq $d.target "local" -}}
cheese-local-manual
{{- else if eq $d.target "aws" -}}
{{- if eq $d.storage.accessMode "ReadWriteMany" -}}efs-sc{{- else -}}gp3{{- end -}}
{{- else -}}
{{- fail (printf "deployment.target %q is not supported (use 'local' or 'aws'; azure is deprecated)" $d.target) -}}
{{- end -}}
{{- end -}}

{{- define "cheese.ingressClass" -}}
{{- $d := .Values.deployment -}}
{{- if $d.ingress.className -}}
{{- $d.ingress.className -}}
{{- else if eq $d.target "aws" -}}
alb
{{- else -}}
nginx
{{- end -}}
{{- end -}}
