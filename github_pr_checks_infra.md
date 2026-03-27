# GitHub PR Checks for the Infrastructure Assignment

Use the following checks as **required status checks** on the repository branch protection rules.

## Recommended Required Checks

### 1. `lint-go`
Purpose:
- enforce formatting and basic Go quality
- catch obvious issues before review

Suggested commands:
```bash
gofmt -l .
go vet ./...
golangci-lint run
```

### 2. `test-go`
Purpose:
- run unit/integration tests for the Go service

Suggested command:
```bash
go test ./... -count=1 -race
```

### 3. `validate-terraform`
Purpose:
- ensure Terraform is formatted and valid

Suggested commands:
```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

### 4. `lint-yaml-k8s`
Purpose:
- validate Kubernetes manifests and YAML quality

Suggested commands:
```bash
yamllint .
kubeconform -strict -summary k8s/**/*.yaml
```

If using Helm:
```bash
helm lint ./helm/config-service
helm template ./helm/config-service | kubeconform -strict -summary
```

### 5. `security-scan`
Purpose:
- catch vulnerable dependencies and obvious secrets/security issues

Suggested tools:
```bash
gosec ./...
trivy fs .
gitleaks detect --no-banner --redact
```

### 6. `build-image`
Purpose:
- ensure the service container actually builds

Suggested command:
```bash
docker build -t config-service:pr .
```

### 7. `smoke-local-manifests`
Purpose:
- ensure manifests/chart render successfully and basic deployment config is coherent

Suggested commands:
```bash
kubectl kustomize k8s/ > /tmp/rendered.yaml
kubeconform -strict -summary /tmp/rendered.yaml
```

Or for Helm:
```bash
helm template config-service ./helm/config-service > /tmp/rendered.yaml
kubeconform -strict -summary /tmp/rendered.yaml
```

---

## Nice-to-Have Checks

These do not all need to be blocking, but they add signal.

### `dependency-review`
- GitHub dependency review for PR dependency changes

### `markdown-lint`
- validate README and docs consistency

### `shellcheck`
- lint bootstrap and deployment scripts

### `kind-e2e`
- stand up a local ephemeral Kind cluster in CI
- deploy Postgres + app
- hit `/ping`
- create a config
- read it back

This is the best end-to-end signal, but it may be slower than the baseline checks.

---

## Branch Protection Recommendation

Set the following as required before merge:

- `lint-go`
- `test-go`
- `validate-terraform`
- `lint-yaml-k8s`
- `security-scan`
- `build-image`

Optionally require:
- conversation resolution
- at least 1 reviewer approval
- linear history / squash merge
- up-to-date branch before merge

---

## Reviewer Checklist for PR Template

Add these items to the PR template so reviewers and candidates explain the important decisions.

### Required PR Description Sections

- Summary of what was implemented
- Infrastructure design
- Kubernetes deployment approach
- Config and secrets strategy
- Database provisioning and migrations
- Observability choices
- Validation steps run locally
- Known limitations / next steps
- Responsible AI usage disclosure

### Author Checklist

- [ ] `gofmt`, `go vet`, and lints pass locally
- [ ] tests pass locally
- [ ] Terraform format and validate pass
- [ ] Kubernetes manifests/chart validate successfully
- [ ] Docker image builds locally
- [ ] README setup steps were tested from a clean state
- [ ] deployment was validated end-to-end
- [ ] AI usage disclosed in PR description if used

---

## Suggested Tooling

### Go
- `golangci-lint`
- `go vet`
- `gofmt`

### Terraform
- `terraform fmt`
- `terraform validate`
- `tflint` (optional but recommended)

### Kubernetes / YAML
- `yamllint`
- `kubeconform`
- `helm lint` or `kubectl kustomize`

### Security
- `gosec`
- `trivy`
- `gitleaks`

### Shell Scripts
- `shellcheck`

---

## Minimum Practical Baseline

If you want the leanest useful setup, start with these 5 blocking checks:

1. Go lint + vet
2. Go tests
3. Terraform fmt + validate
4. Kubernetes manifest validation
5. Docker build

That is the smallest set that still gives good automatic PR review signal.
