IMAGE_NAME     ?= config-service
IMAGE_TAG      ?= local
CLUSTER_NAME   ?= config-service
NAMESPACE      ?= config-service
HELM_RELEASE   ?= config-service
HELM_CHART_DIR  = deployments/helm/config-service
REGISTRY       ?= localhost:5001

.PHONY: all cluster build docker docker-push migrate deploy test smoke destroy clean \
        terraform terraform-init terraform-plan terraform-apply terraform-destroy \
        helm-lint lint vet fmt check logs port-forward

all: cluster build docker migrate deploy smoke

# ─── Cluster ──────────────────────────────────────────────────────────────────
cluster: ## Create Kind cluster
	@echo "▶ Creating Kind cluster: $(CLUSTER_NAME)"
	@kind get clusters | grep -q $(CLUSTER_NAME) || kind create cluster \
		--name $(CLUSTER_NAME) \
		--config deployments/manifests/kind-config.yaml
	@echo "▶ Setting kubectl context"
	kubectl cluster-info --context kind-$(CLUSTER_NAME)

# ─── Build ────────────────────────────────────────────────────────────────────
build: ## Build Go binary
	@echo "▶ Building Go binary"
	CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -trimpath -o bin/config-service ./cmd/server

docker: ## Build Docker image
	@echo "▶ Building Docker image $(IMAGE_NAME):$(IMAGE_TAG)"
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(IMAGE_NAME):latest

docker-push: docker ## Push image to registry
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)
	docker push $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

kind-load: docker ## Load image into Kind cluster
	@echo "▶ Loading image into Kind"
	kind load docker-image $(IMAGE_NAME):$(IMAGE_TAG) --name $(CLUSTER_NAME)
	kind load docker-image $(IMAGE_NAME):latest --name $(CLUSTER_NAME)

# ─── Terraform ────────────────────────────────────────────────────────────────
terraform-init: ## Terraform init
	cd terraform/local && terraform init

terraform-plan: terraform-init ## Terraform plan
	cd terraform/local && terraform plan -var="db_password=configpass"

terraform: terraform-init ## Apply Terraform (provisions namespace, secrets, configmap)
	@echo "▶ Applying Terraform"
	cd terraform/local && terraform apply -auto-approve -var="db_password=configpass"

terraform-destroy: ## Destroy Terraform resources
	cd terraform/local && terraform destroy -auto-approve -var="db_password=configpass"

# ─── Migrations ───────────────────────────────────────────────────────────────
migrate: ## Run database migrations
	@echo "▶ Running migrations"
	./scripts/migrate.sh

migrate-down: ## Roll back last migration
	migrate -path migrations -database "$(DATABASE_URL)" down 1

# ─── Deploy ───────────────────────────────────────────────────────────────────
deploy: kind-load terraform ## Deploy application via Helm
	@echo "▶ Deploying Helm release: $(HELM_RELEASE)"
	helm upgrade --install $(HELM_RELEASE) $(HELM_CHART_DIR) \
		--namespace $(NAMESPACE) \
		--create-namespace \
		--wait \
		--timeout 5m \
		-f $(HELM_CHART_DIR)/values.yaml

deploy-local: ## Deploy with docker-compose
	docker-compose up -d --build

# ─── Testing ──────────────────────────────────────────────────────────────────
test: ## Run unit tests
	@echo "▶ Running unit tests"
	go test ./... -race -count=1 -timeout 60s -v

test-coverage: ## Run tests with coverage report
	go test ./... -race -coverprofile=coverage.out -covermode=atomic
	go tool cover -html=coverage.out -o coverage.html
	@echo "Coverage report: coverage.html"

smoke: ## Run smoke tests against running service
	@echo "▶ Running smoke tests"
	./scripts/smoke-test.sh

# ─── Code Quality ─────────────────────────────────────────────────────────────
lint: ## Run golangci-lint
	golangci-lint run ./...

vet: ## Run go vet
	go vet ./...

fmt: ## Format Go code
	gofmt -w .

check: vet lint ## Run all code quality checks

# ─── Helm ─────────────────────────────────────────────────────────────────────
helm-lint: ## Lint Helm chart
	helm lint $(HELM_CHART_DIR)

helm-template: ## Render Helm templates (dry-run)
	helm template $(HELM_RELEASE) $(HELM_CHART_DIR) \
		--namespace $(NAMESPACE) \
		-f $(HELM_CHART_DIR)/values.yaml

helm-diff: ## Show diff between deployed and local chart
	helm diff upgrade $(HELM_RELEASE) $(HELM_CHART_DIR) \
		--namespace $(NAMESPACE) \
		-f $(HELM_CHART_DIR)/values.yaml

# ─── Operations ───────────────────────────────────────────────────────────────
logs: ## Tail application logs
	kubectl -n $(NAMESPACE) logs -l app.kubernetes.io/name=config-service -f --tail=100

port-forward: ## Port-forward service to localhost:8080
	kubectl -n $(NAMESPACE) port-forward svc/$(HELM_RELEASE) 8080:8080

status: ## Show deployment status
	kubectl -n $(NAMESPACE) get pods,svc,deploy,hpa

# ─── Cleanup ──────────────────────────────────────────────────────────────────
destroy: ## Delete Kind cluster
	kind delete cluster --name $(CLUSTER_NAME)

clean: ## Remove build artifacts
	rm -rf bin/ coverage.out coverage.html

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
