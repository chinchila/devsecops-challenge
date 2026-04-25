REGISTRY        ?= ghcr.io/chinchila/devsecops-challenge
IMAGE_TAG       ?= latest
PROJECT_ID      ?= a
REGION          ?= us-central1
CLUSTER_NAME    ?= devsecops-challenge
TF_BUCKET       ?= $(PROJECT_ID)-tf-state
MY_IP           ?= $(shell curl -s ifconfig.me)/32

.PHONY: help build build-insecure push sign verify-sign \
        tf-init tf-plan tf-apply tf-destroy \
        kubeconfig validate-network validate-runtime validate-secrets \
        falco-demo-shell falco-demo-file kube-bench \
        argocd-sync argocd-status lint-go

lint-go: ## Run go vet + staticcheck
	go vet ./...
	@which staticcheck 2>/dev/null && staticcheck ./... || echo "staticcheck not installed, skipping"

build: ## Build production image
	docker build -f Dockerfile -t $(REGISTRY):$(IMAGE_TAG) -t $(REGISTRY):latest .
	@echo "✓ Built $(REGISTRY):$(IMAGE_TAG)"

build-insecure: ## Build insecure image (for CI demo - do not push)
	docker build -f insecure.Dockerfile -t insecure-test:ci .
	@echo "✓ Built insecure-test:ci (expected to have CRITICAL CVEs)"

push: build ## Push production image to registry
	docker push $(REGISTRY):$(IMAGE_TAG)
	docker push $(REGISTRY):latest

scan-prod: build ## Trivy scan production image
	trivy image --severity CRITICAL,HIGH --exit-code 1 $(REGISTRY):$(IMAGE_TAG)

scan-insecure: build-insecure ## Trivy scan insecure image (expect failure)
	@echo "→ Scanning insecure image - expecting CRITICAL CVEs..."
	trivy image --severity CRITICAL --exit-code 1 insecure-test:ci; \
		[ $$? -ne 0 ] && echo "✓ Gate correctly blocked insecure image" || \
		(echo "✗ ERROR: no CVEs found in insecure image - check base image" && exit 1)

sign: ## Sign image with Cosign (requires COSIGN_PRIVATE_KEY env var)
	@[ -f cosign.key ] || (echo "cosign.key not found - run: cosign generate-key-pair" && exit 1)
	cosign sign --key cosign.key --yes $(REGISTRY):$(IMAGE_TAG)
	@echo "✓ Image signed"

verify-sign: ## Verify Cosign signature
	@[ -f cosign.pub ] || (echo "cosign.pub not found" && exit 1)
	cosign verify --key cosign.pub $(REGISTRY):$(IMAGE_TAG)
	@echo "✓ Signature valid"

tf-bucket:
	gcloud storage buckets create gs://$(TF_BUCKET) \
		--project=$(PROJECT_ID) \
		--location=$(REGION) \
		--uniform-bucket-level-access
	@echo "✓ Bucket gs://$(TF_BUCKET) created"

tf-init:
	cd infra && /snap/bin/tofu init \
		-backend-config="bucket=$(TF_BUCKET)" \
		-backend-config="prefix=devsecops-challenge/state"

tf-plan: tf-init
	cd infra && /snap/bin/tofu plan \
		-lock=false \
		-var="project_id=$(PROJECT_ID)" \
		-var="region=$(REGION)" \
		-var="master_authorized_cidr=$(MY_IP)" \
		-var="image_registry=$(REGISTRY)"

tf-apply: tf-init
	cd infra && /snap/bin/tofu apply \
	    -lock=false \
		-var="project_id=$(PROJECT_ID)" \
		-var="region=$(REGION)" \
		-var="master_authorized_cidr=$(MY_IP)" \
		-var="image_registry=$(REGISTRY)" \
		-auto-approve

tf-destroy:
	cd infra && /snap/bin/tofu destroy \
		-lock=false \
		-var="project_id=$(PROJECT_ID)" \
		-var="region=$(REGION)" \
		-var="master_authorized_cidr=$(MY_IP)" \
		-var="image_registry=$(REGISTRY)"

kubeconfig: ## Get kubeconfig for the cluster
	gcloud container clusters get-credentials $(CLUSTER_NAME) \
		--region $(REGION) --project $(PROJECT_ID)

validate-pss: ## Verify PSS restricted labels on app namespaces
	@echo "=== Pod Security Standard labels ==="
	@for ns in service-1 service-2 service-3; do \
		echo "--- $$ns ---"; \
		kubectl get ns $$ns -o jsonpath='{.metadata.labels}' | python3 -m json.tool; \
	done

validate-mtls: ## Verify Istio mTLS STRICT is active
	@echo "=== PeerAuthentication ==="
	kubectl get peerauthentication -A
	@echo ""
	@echo "=== mTLS status (service-1) ==="
	istioctl x describe pod -n service-1 \
		$$(kubectl get pod -n service-1 -l app=service-1 -o name | head -1 | cut -d/ -f2)

validate-network: ## Test NetworkPolicy enforcement
	@echo "=== Testing lateral movement block: service-1 → service-3 ==="
	@POD=$$(kubectl get pod -n service-1 -l app=service-1 -o name | head -1); \
		kubectl exec $$POD -n service-1 -c service-1 -- \
			wget -qO- --timeout=3 http://service-3.service-3.svc.cluster.local:8080/ 2>&1 || \
		echo "✓ Blocked (expected)"
	@echo ""
	@echo "=== Testing allowed path: service-1 → service-2 ==="
	@POD=$$(kubectl get pod -n service-1 -l app=service-1 -o name | head -1); \
		kubectl exec $$POD -n service-1 -c service-1 -- \
			wget -qO- --timeout=5 http://service-2.service-2.svc.cluster.local:8080/ 2>&1
	@echo "✓ service-2 reachable (expected)"

validate-secrets: ## Verify JWT_SECRET not in plaintext anywhere
	@echo "=== Checking for plaintext secrets in repository ==="
	@git grep -r "JWT_SECRET.*=" -- '*.yaml' '*.tf' '*.go' '*.json' \
		| grep -v "secretKeyRef\|name: JWT_SECRET\|key: JWT_SECRET\|JWT_SECRET env var\|JWT_SECRET configured" \
		&& echo "✗ Potential plaintext secret found" || echo "✓ No plaintext secrets found"
	@echo ""
	@echo "=== Checking Infisical sync in service-1 ==="
	@kubectl get secret app-secrets -n service-1 -o jsonpath='{.metadata.annotations}' 2>/dev/null | \
		python3 -m json.tool || echo "Secret not yet synced - run Infisical bootstrap first"

validate-argocd: ## Check Argo CD application sync status
	@echo "=== Argo CD Application Status ==="
	kubectl get applications -n argocd

validate-falco: ## Show recent Falco alerts
	@echo "=== Falco alerts (last 5 minutes) ==="
	kubectl logs -n falco -l app.kubernetes.io/name=falco \
		--since=5m --tail=100 2>/dev/null | \
		grep -E '"priority":"(CRITICAL|ERROR|WARNING)"' | \
		python3 -m json.tool 2>/dev/null || \
		kubectl logs -n falco -l app.kubernetes.io/name=falco --since=5m --tail=100

validate-all: validate-pss validate-mtls validate-network validate-secrets validate-argocd ## Run all validations

falco-demo-setup: ## Create a debug pod in service-1 for Falco demos
	kubectl run falco-demo \
		--image=alpine:3.19 \
		--namespace=service-1 \
		--restart=Never \
		--overrides='{"spec":{"securityContext":{"runAsUser":65532,"runAsNonRoot":true},"containers":[{"name":"falco-demo","image":"alpine:3.19","command":["sleep","3600"],"securityContext":{"runAsUser":65532,"runAsNonRoot":true,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl wait --for=condition=Ready pod/falco-demo -n service-1 --timeout=60s
	@echo "✓ Demo pod ready - run 'make falco-demo-shell' and 'make falco-demo-file'"

falco-demo-shell: ## Trigger Falco alert: shell execution (T-RT-01)
	@echo "=== Triggering: Shell Executed in App Container ==="
	kubectl exec -n service-1 falco-demo -- sh -c "echo triggered"
	@echo "→ Check Falco logs: kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=20"

falco-demo-file: ## Trigger Falco alert: sensitive file read (T-RT-02)
	@echo "=== Triggering: Sensitive File Read in App Container ==="
	kubectl exec -n service-1 falco-demo -- sh -c "cat /etc/passwd" 2>/dev/null || true
	@echo "→ Check Falco logs: kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=20"

falco-demo-cleanup: ## Remove the Falco demo pod
	kubectl delete pod falco-demo -n service-1 --ignore-not-found=true
	@echo "✓ Demo pod removed"

falco-watch: ## Stream Falco alerts in real time
	kubectl logs -n falco -l app.kubernetes.io/name=falco --follow

kube-bench: ## Run kube-bench CIS benchmark job
	kubectl apply -f k8s/security/kube-bench-job.yaml
	@echo "Waiting for kube-bench job..."
	kubectl wait --for=condition=Complete job/kube-bench -n kube-system --timeout=120s
	kubectl logs job/kube-bench -n kube-system

argocd-port-forward: ## Port-forward Argo CD UI to localhost:8080
	kubectl port-forward svc/argocd-server -n argocd 8080:443

argocd-sync: ## Force sync all Argo CD applications
	argocd app sync service-1 service-2 service-3 security-controls

argocd-status: ## Show all Argo CD application statuses
	argocd app list
