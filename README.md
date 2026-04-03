# Kulu Infrastructure Engineering Assignment

This repository contains the take-home infrastructure assignment for engineering candidates at Kulu.

## How to Submit

1. **Fork this repository** to your own GitHub account.
2. Complete the assignment described in [`INFRA_ASSIGNMENT.md`](./INFRA_ASSIGNMENT.md).
3. **Raise a Pull Request** back to this repository (`main` branch) with your full solution.

Your PR branch should be named: `solution/<your-name>` (e.g., `solution/jane-doe`).

---

## Assignment Summary

You are asked to build and deploy a small **Kubernetes Config Service** locally. The assignment evaluates your ability to work across:

- Go application development (HTTP API + PostgreSQL)
- Kubernetes deployment (Helm, Minikube, Kind, k3d, or similar)
- Infrastructure as Code (Terraform or equivalent)
- Local automation and reproducibility
- Operational readiness and observability

Full details, requirements, and deliverable expectations are in [`INFRA_ASSIGNMENT.md`](./INFRA_ASSIGNMENT.md).

---

## What Your PR Must Include

- Go application source code
- Kubernetes manifests / Helm chart / Kustomize config
- Infrastructure code (Terraform or equivalent)
- Setup and deployment automation (Makefile, scripts, etc.)
- Documentation covering local setup, deployment, and validation

Your PR description must address:

1. Infrastructure design choices
2. Configuration and secret handling
3. Operational readiness (health checks, failure handling, observability)
4. Repository structure explanation
5. Responsible AI usage disclosure

See [`INFRA_ASSIGNMENT.md`](./INFRA_ASSIGNMENT.md) for the full checklist.

---

## Time Expectation

Please spend **1–2 days** on this assignment. We value clear reasoning, repeatable automation, and well-documented tradeoffs over completeness.

---

## Questions

If anything is unclear, feel free to reach out to your hiring contact.
