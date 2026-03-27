# Kubernetes Config Service — Infrastructure Engineering Assignment

## Overview

Build and deploy a small **configuration service** on a local Kubernetes environment.

The goal of this assignment is to evaluate your ability to design and operate a **reliable local infrastructure setup** with clear thinking about:

- infrastructure as code
- Kubernetes deployment design
- configuration and secret management
- database provisioning
- deployment automation
- local reproducibility
- observability and operational readiness

This assignment is intentionally not just about getting a container to run. We want to evaluate how you think about **repeatable environments, operability, and production-style engineering tradeoffs**.

Focus on **clarity, correctness, automation, and maintainability**, not on building a large application.

---

## Problem Statement

You need to implement and deploy a small application that manages configuration records.

The application should be written in **Golang** and deployed to **Kubernetes** using a **local setup** such as Minikube, Kind, k3d, or another comparable tool of your choice.

The system should include:

- a Go application exposing HTTP APIs
- a PostgreSQL database
- infrastructure provisioning using **Terraform** or another IaC tool
- deployment automation for local Kubernetes
- clear documentation for setup, provisioning, deployment, and validation

We are looking for evidence that you can move comfortably across application packaging, infrastructure provisioning, deployment workflows, and day-2 operational concerns.

---

## Application Requirements

The application must expose the following endpoints.

### 1. Health Check Endpoint

```text
GET /ping
```

Expected response:

```text
pong
```

This endpoint should be suitable for basic liveness/readiness-style checks.

### 2. Config Retrieval Endpoint

```text
GET /configs/:id
```

Returns the config with the given identifier from the database.

You should define and document:

- what `:id` represents
- the response shape
- behavior when the config does not exist
- validation and error handling

### 3. Config Upsert Endpoint

```text
POST /configs
```

Creates or updates a config record.

Example request body:

```json
{
  "id": "cfg_1",
  "host": "localhost",
  "port": 8080,
  "app_name": "config-service",
  "log_level": "INFO"
}
```

You may extend the schema slightly if needed, but the core fields should remain:

- `host`
- `port`
- `app_name`
- `log_level`

Document your upsert behavior clearly.

---

## Database Requirements

Use PostgreSQL.

At minimum, the database should contain a `configs` table supporting the application requirements.

Your schema should include:

- a primary key
- sensible data types
- constraints where appropriate
- any indexes required by your design

Please document:

- why you chose the schema
- how the schema is created or migrated
- how local provisioning is automated

---

## Infrastructure Requirements

Your submission must provision and run all required components **locally**.

### Required Components

At minimum, your local setup should include:

- Kubernetes cluster
- application deployment
- PostgreSQL database
- service exposure sufficient for local testing
- repeatable automation for bootstrap and deployment

### Infrastructure as Code

Use **Terraform** or another IaC tool of your choice to provision the database and/or other local infrastructure components.

Examples of acceptable scope:

- provisioning local PostgreSQL resources
- provisioning Kubernetes resources
- combining Terraform with Helm or manifests
- using Terraform mainly for environment setup, with Kubernetes manifests for deployment

If you choose a different split of responsibilities, explain it clearly.

### Kubernetes Deployment

Your solution should deploy the application into Kubernetes and include the required manifests, chart, or equivalent configuration.

You may use:

- raw Kubernetes YAML
- Kustomize
- Helm
- another well-structured approach

Document your deployment strategy and tradeoffs.

---

## Expectations for Local Reproducibility

We should be able to understand how to reproduce your environment on a clean local machine.

At minimum, automate:

1. local cluster setup
2. infrastructure provisioning
3. schema setup or migrations
4. application deployment
5. validation steps

This may be done with:

- Makefile targets
- shell scripts
- task runner
- CI workflow used locally
- another approach of your choice

The important thing is that the workflow is explicit and repeatable.

---

## Architecture Expectations

We expect a solution that is easy to reason about across both application and infrastructure layers.

### Application Structure

Use well-structured Go code with clear separation of concerns. For example:

```text
handler layer
service layer
repository layer
domain models / DTOs
```

Handlers should stay thin. Persistence concerns should not be mixed directly into HTTP routing where avoidable.

### Infrastructure Structure

We expect infrastructure code to be organized clearly, for example by:

- environment
- module
- component
- deployment layer

The structure should make it obvious how the system is provisioned and deployed.

---

## Documentation-First Workflow

Before writing substantial implementation, document the intended system behavior and operating model.

At minimum, document:

- API contracts
- local architecture
- deployment flow
- infrastructure components
- configuration and secrets strategy
- health checking approach
- persistence setup
- operational assumptions
- known limitations

This can live in `README.md`, design notes, or short markdown documents.

We are explicitly evaluating whether you can make operational behavior understandable before and alongside implementation.

---

## Reliability and Operational Expectations

Even though this runs locally, design with production-style thinking.

Please consider and document the following:

- how the application gets database connection details
- what happens when the database is unavailable
- how the service signals readiness versus liveness
- how configuration is injected
- how secrets are handled
- how the deployment can be repeated safely
- how we can verify that the system is healthy after deployment

You do not need to solve every production concern fully, but we do want to see sound operational judgment.

---

## Observability Expectations

At minimum, your solution should include a basic observability story.

Examples:

- structured logs
- useful startup logs
- readiness/liveness probes
- metrics endpoint if you choose
- clear troubleshooting guidance in the README

Bonus points for:

- Prometheus-compatible metrics
- dashboards
- traceability between request handling and persistence
- failure visibility during startup/deployment

---

## CI/CD and Packaging (Bonus)

Bonus credit if you include any of the following:

- CI pipeline configuration
- automated test execution
- image build and publish workflow
- Helm chart
- deployment validation checks
- smoke test automation

This is optional. Depth is more valuable than breadth.

---

## Testing Expectations

We do not require a massive test suite, but we do expect deliberate validation.

### Minimum Testing Expectations

Include some combination of:

- application tests for core endpoint behavior
- infrastructure validation steps
- deployment smoke tests
- database integration verification

At minimum, show that you have thought about how to validate:

- the app starts correctly
- the app can reach the database
- configs can be created and retrieved
- the deployment is operational after rollout

If you skip automated tests in some area, explain why and what you would test next.

---

## Deliverables

Please submit your solution as a **Pull Request**.

Your PR should include:

- Go application code
- infrastructure code
- Kubernetes manifests/chart/configuration
- setup and deployment automation
- documentation for local execution and validation

### Required PR Description

Your PR description must explicitly explain:

1. **Infrastructure design**
   - cluster choice
   - database provisioning approach
   - deployment strategy
   - networking/service exposure choices

2. **Configuration and secret handling**
   - how config is supplied
   - how secrets are managed locally
   - what you would change for production

3. **Operational readiness**
   - health checks
   - rollout/restart considerations
   - observability choices
   - failure handling assumptions

4. **Repository structure**
   - where app code lives
   - where infra code lives
   - why the layout is maintainable

5. **Responsible AI usage**
   - whether you used AI tools
   - where they helped
   - what you personally verified or corrected

Please be candid. AI usage is allowed; engineering judgment still matters.

---

## Time Expectation

Please spend **3–5 hours** on this assignment.

We do not expect a perfect production platform. We care more about:

- clear reasoning
- repeatable setup
- maintainable structure
- sensible operational defaults
- honest tradeoff discussion

---

## What We Are Optimizing For

A strong submission is one that is:

- easy to run locally
- automated and reproducible
- well-structured
- operationally thoughtful
- clearly documented

A smaller, well-reasoned solution is preferred over a broader but fragile one.
