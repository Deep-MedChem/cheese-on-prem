{{/*
Defaults for the two cluster-specific strings this chart cannot guess: the
storage class of the PVC it provisions, and the ingress class. deployment.target
is a shorthand for a known pair of them — it is NOT a list of platforms CHEESE
supports. Nothing else in the chart varies by target, images included: they come
from ECR wherever you deploy.

  local : kind / bare-metal dev. hostPath PV (storageClass cheese-local-manual),
          nginx ingress. This is the only target that also renders a PV.
  aws    : gp3 (RWO) or efs-sc (RWX) storage, alb ingress. Class names only —
          correct, but never run end to end.

Any conformant cluster works. If yours uses different class names, set
deployment.storage.className / deployment.ingress.className — an explicit class
always wins, and setting both makes the target irrelevant. Bringing your own
claim (data.existingClaim) skips the storage class entirely.
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
{{- fail (printf "deployment.target %q has no built-in storage-class default. Set deployment.storage.className explicitly (or use data.existingClaim); the built-in pairs are 'local' and 'aws'." $d.target) -}}
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
