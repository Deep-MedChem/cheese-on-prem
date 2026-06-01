.PHONY: build-source-images load-images install-ingress-controller

build-source-images:
	./scripts/build-source-images.sh

load-images:
	./scripts/load-kind-images.sh

install-ingress-controller:
	kubectl label node kind-control-plane ingress-ready=true --overwrite
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml
	kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s
