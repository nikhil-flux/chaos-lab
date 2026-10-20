CLUSTER ?= chaos-lab
IMAGE   ?= chaos-lab-app:local
export KUBECONFIG ?= $(CURDIR)/terraform/$(CLUSTER)-kubeconfig

.DEFAULT_GOAL := help
.PHONY: help up build load-image apply deploy test fmt load grafana prometheus alertmanager chaos-ui \
        chaos-kill chaos-delay chaos-outage chaos-cpu gameday chaos-stop smoke status down

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-14s %s\n", $$1, $$2}'

up: ## Create the kind cluster, Chaos Mesh and the monitoring stack (Terraform)
	cd terraform && terraform init && terraform apply -auto-approve

build: ## Build the app image
	docker build -t $(IMAGE) app

load-image: ## Load the app image into the kind cluster
	kind load docker-image $(IMAGE) --name $(CLUSTER)

apply: ## Apply app manifests, ServiceMonitor and alert rules
	kubectl apply -k k8s
	kubectl apply -f monitoring/servicemonitor.yaml -f monitoring/alert-rules.yaml
	kubectl -n shop wait --for=condition=Available deploy --all --timeout=180s

deploy: build load-image apply ## Build, load and deploy the app

test: ## Run unit tests
	cd app && pip install -q -r requirements-dev.txt && python -m pytest -q

fmt: ## Format Terraform files
	cd terraform && terraform fmt -recursive

load: ## Generate traffic: make load [DURATION=300] [WORKERS=5]
	./scripts/load.sh $(or $(DURATION),300) $(or $(WORKERS),5)

grafana: ## Open Grafana at http://localhost:3000 (user: admin)
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

prometheus: ## Open Prometheus at http://localhost:9090
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090

alertmanager: ## Open Alertmanager at http://localhost:9093
	kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093

chaos-ui: ## Open the Chaos Mesh dashboard at http://localhost:2333
	kubectl -n chaos-mesh port-forward svc/chaos-dashboard 2333:2333

chaos-kill: ## Experiment 1: kill one inventory pod
	kubectl apply -f chaos/pod-kill.yaml

chaos-delay: ## Experiment 2: add 800ms latency to inventory for 3 minutes
	kubectl apply -f chaos/network-delay.yaml

chaos-outage: ## Experiment 3: take inventory fully down for 90 seconds
	kubectl apply -f chaos/pod-failure.yaml

chaos-cpu: ## Experiment 4: stress CPU in one orders pod for 2 minutes
	kubectl apply -f chaos/cpu-stress.yaml

gameday: ## Run every experiment in sequence (about 10 minutes)
	kubectl apply -f chaos/gameday-workflow.yaml

chaos-stop: ## Remove all running experiments
	-kubectl delete -f chaos/ --ignore-not-found

smoke: ## Resilience gate: pod-kill under load must stay >= 85% successful
	./scripts/smoke.sh

status: ## Show pods and chaos experiments
	kubectl -n shop get pods -o wide
	kubectl -n shop get podchaos,networkchaos,stresschaos,workflow 2>/dev/null || true

down: ## Destroy everything
	cd terraform && terraform destroy -auto-approve
