IMAGE_NAME     ?= config-service
IMAGE_TAG      ?= local
CLUSTER_NAME   ?= config-service
NAMESPACE      ?= config-service
HELM_RELEASE   ?= config-service
HELM_CHART_DIR  = deployments/helm/config-service

.PHONY: all cluster build docker docker-push migrate deploy test smoke destroy clean \
        terraform terraform-init terraform-plan terraform-apply terraform-destroy \
        helm-lint lint vet fmt check logs port-forward

all: cluster build docker migrate deploy smoke

# ─── Cluster ──────────────────────────────────────────────────────────────────
cluster: ## Create Minikube cluster and deploy full stack
	@echo "▶ Running Minikube setup (Postgres · Kafka · App · Observability)"
	./scripts/minikube-setup.sh

# ─── Build ────────────────────────────────────────────────────────────────────
build: ## Build Go binary
	@echo "▶ Building Go binary"
	CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -trimpath -o bin/config-service ./cmd/server

docker: ## Build Docker image
	@echo "▶ Building Docker image $(IMAGE_NAME):$(IMAGE_TAG)"
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(IMAGE_NAME):latest

docker-push: docker ## Push image to registry
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) localhost:5001/$(IMAGE_NAME):$(IMAGE_TAG)
	docker push localhost:5001/$(IMAGE_NAME):$(IMAGE_TAG)

minikube-load: docker ## Load image into Minikube
	@echo "▶ Loading image into Minikube"
	minikube image load $(IMAGE_NAME):$(IMAGE_TAG) --profile $(CLUSTER_NAME)
	minikube image load $(IMAGE_NAME):latest --profile $(CLUSTER_NAME)

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
deploy: minikube-load ## Deploy application via Helm into Minikube
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

port-forward: ## Port-forward all services (run in separate terminal)
	@echo "Forwarding: config-service=8080 grafana=3000 prometheus=9090 jaeger=16686"
	kubectl -n $(NAMESPACE) port-forward svc/config-service 8080:80 &
	kubectl -n $(NAMESPACE) port-forward svc/prometheus-grafana 3000:80 &
	kubectl -n $(NAMESPACE) port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 &
	kubectl -n $(NAMESPACE) port-forward svc/jaeger-allInOne 16686:16686 &
	@wait

status: ## Show deployment status
	kubectl -n $(NAMESPACE) get pods,svc,deploy,hpa

# ─── Cleanup ──────────────────────────────────────────────────────────────────
destroy: ## Delete Minikube cluster
	minikube delete --profile $(CLUSTER_NAME)

clean: ## Remove build artifacts
	rm -rf bin/ coverage.out coverage.html

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
