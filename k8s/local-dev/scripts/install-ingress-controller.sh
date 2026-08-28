#!/usr/bin/env bash
#
# Install ingress-nginx on the kind cluster: label the node so the
# kind-flavoured manifest schedules onto it, apply the manifest, and wait
# for the controller to roll out. Idempotent — safe to re-run.

set -euo pipefail

kubectl label node kind-control-plane ingress-ready=true --overwrite
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
