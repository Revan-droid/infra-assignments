# Evaluation Guide — Kubernetes Config Service

## Purpose of This Guide

This guide helps reviewers evaluate whether the candidate demonstrated strong infrastructure engineering judgment for a local Kubernetes-based service deployment.

The assignment is not just about writing a small API. It is about whether the candidate can design a **repeatable, operable, well-structured local platform setup** with sensible tradeoffs.

Use this rubric to evaluate both the implementation and the pull request description.

---

## Reviewer Mindset

Look for:

- reproducibility before cleverness
- operational clarity
- maintainable infrastructure structure
- good defaults for local deployment
- sound configuration and secret handling
- pragmatic observability
- clear documentation and validation steps

Do not over-index on specific tools if the chosen approach is coherent and well explained.

---

## Scoring Rubric

You may score each category on a 1–4 scale:

- **1 — Weak**
- **2 — Mixed / Partial**
- **3 — Strong**
- **4 — Exceptional**

A strong overall submission will usually score mostly 3s, with one or more 4s in areas such as automation, operability, or clarity.

---

## 1) Infrastructure Design

### What Reviewers Should Look For

- sensible local architecture
- clear separation of app, database, and deployment concerns
- coherent choice of local Kubernetes environment
- practical service exposure for local use
- thoughtfulness around how components connect

### Strong Signals

- clear explanation of why Minikube, Kind, k3d, or another local cluster was chosen
- infrastructure code organized by component or layer
- application and database dependencies are explicit
- network/service setup is easy to understand
- deployment flow is easy to follow end-to-end

### Weak Signals

- manually assembled environment with little structure
- unclear relationship between cluster, database, and app
- tool choices made without explanation
- infrastructure code scattered or difficult to navigate

### Reviewer Questions

- Can I understand the local architecture quickly?
- Is the system layout maintainable?
- Did the candidate make choices intentionally, or just assemble defaults?

---

## 2) Infrastructure as Code and Automation

### What Reviewers Should Look For

- use of Terraform or another IaC tool in a meaningful way
- repeatable setup and deployment steps
- reduced manual intervention
- clear automation entrypoints

### Strong Signals

- one or a few commands can bootstrap most of the environment
- provisioning steps are scripted or codified
- automation handles common setup tasks reliably
- database setup and deployment are not dependent on hidden manual steps
- README aligns with the actual automation flow

### Weak Signals

- mostly manual instructions
- IaC present but superficial
- important setup steps omitted from automation
- instructions appear untested or incomplete

### Reviewer Questions

- Could another engineer reproduce this locally without guessing?
- Are setup and deployment steps mostly automated?
- Does the submitted automation reflect real usage, or is it aspirational?

---

## 3) Kubernetes Deployment Quality

### What Reviewers Should Look For

- reasonable manifests/chart structure
- correct use of Deployments, Services, ConfigMaps, Secrets, or equivalents
- readiness/liveness awareness
- rollout and restart behavior considered

### Strong Signals

- probes are configured appropriately
- resource definitions are sensible for local use
- configuration is injected cleanly
- manifests are organized and readable
- deployment is reproducible and not overly fragile

### Weak Signals

- Kubernetes resources included with minimal understanding
- no readiness/liveness distinction
- config hardcoded into images or source when avoidable
- deployment depends on manual patching or editing after apply

### Reviewer Questions

- Would the deployment behave predictably after restart or rollout?
- Are Kubernetes primitives used clearly and appropriately?
- Is there evidence of operational understanding, not just YAML generation?

---

## 4) Database Provisioning and Persistence

### What Reviewers Should Look For

- PostgreSQL is provisioned coherently
- schema setup is automated or clearly documented
- persistence decisions are appropriate for a local environment
- app/database integration is reliable

### Strong Signals

- schema creation or migration is part of the setup flow
- database connection settings are externalized cleanly
- candidate explains what is local-only versus production-grade
- app startup and database dependency handling are considered

### Weak Signals

- database is assumed to exist with vague setup instructions
- schema must be created manually without documentation
- connection settings are hardcoded
- database integration is brittle or under-explained

### Reviewer Questions

- Can I provision and initialize the database without ad hoc steps?
- Is persistence setup aligned with the rest of the automation?
- Did the candidate think about app behavior during database unavailability?

---

## 5) Configuration and Secrets Management

### What Reviewers Should Look For

- clear handling of configuration values
- separation between configuration and secrets
- local-safe approach with production awareness
- minimal hardcoding

### Strong Signals

- ConfigMaps/Secrets or equivalent approach used appropriately
- database credentials not buried across multiple files without explanation
- candidate explains how they would evolve local secret handling for production
- environment variables and runtime config are documented clearly

### Weak Signals

- secrets committed casually with no comment
- config and secret values mixed in confusing ways
- no explanation of runtime configuration flow
- operational values hidden in source code

### Reviewer Questions

- Is it obvious where configuration comes from?
- Are secrets handled intentionally for a local assignment?
- Has the candidate separated local convenience from production advice?

---

## 6) Observability and Operational Readiness

### What Reviewers Should Look For

- health checking is meaningful
- logs are useful
- troubleshooting path is clear
- operational assumptions are documented

### Strong Signals

- `/ping` is wired into probes or validation flow appropriately
- logs are structured or at least useful
- startup failures are visible and diagnosable
- README includes ways to inspect pods, services, logs, or rollout status
- candidate calls out what extra observability would be added in production

### Weak Signals

- health endpoint exists but is operationally disconnected
- logs provide little diagnostic value
- no mention of how to determine if deployment succeeded
- failure states are opaque

### Reviewer Questions

- Can an engineer tell whether the system is healthy?
- If deployment fails, are there clear ways to debug it?
- Does the candidate think in terms of day-2 operations?

---

## 7) Layering and Code Quality

### What Reviewers Should Look For

- thin handlers
- clear application structure
- reasonable repository/service separation
- understandable code flow
- minimal unnecessary complexity

### Strong Signals

- handlers mostly parse and delegate
- persistence code is isolated
- business behavior is easy to follow
- code style is consistent and pragmatic
- repository layout mirrors system responsibilities

### Weak Signals

- routing, persistence, and domain logic mixed together
- structure is difficult to navigate
- abstractions exist only cosmetically
- excessive complexity for a small service

### Reviewer Questions

- Is the code easy to review and extend?
- Are responsibilities separated clearly?
- Does the structure reflect deliberate engineering choices?

---

## 8) Testing and Validation

### What Reviewers Should Look For

- endpoint validation
- database integration validation
- deployment smoke tests or equivalent checks
- evidence that the candidate validated the full setup

### Strong Signals

- basic application tests exist
- smoke test steps are documented and realistic
- candidate verifies create/read behavior against the deployed system
- tests or scripts target important paths, not just compilation

### Weak Signals

- little evidence of validation
- only unit tests with no deployment verification
- instructions imply behavior was not tested end-to-end
- important setup assumptions remain unverified

### Reviewer Questions

- Did the candidate test the system as deployed?
- Is there confidence that local setup actually works?
- Are validation steps clear enough for another engineer to repeat?

---

## Suggested Overall Rating Bands

### Exceptional
The submission is highly reproducible, operationally thoughtful, and easy to reason about.  
Infrastructure, deployment, and documentation reinforce one another well.

### Strong
The solution is practical, clear, and mostly automated.  
There may be some simplifications, but the candidate demonstrates strong engineering judgment.

### Mixed
The system works partially or the candidate shows promise, but reproducibility, operability, or structure is uneven.

### Weak
The solution behaves more like an ad hoc demo than a maintainable infrastructure assignment.  
Automation, clarity, and operational thinking are limited.

---

## Common Failure Patterns

Reviewers should watch for these:

- setup relies heavily on undocumented manual steps
- Terraform or IaC included but not meaningfully used
- Kubernetes manifests copied in without operational reasoning
- no clear distinction between config and secrets
- no readiness/liveness thinking
- database provisioning or migrations under-documented
- README does not match actual workflow
- no end-to-end validation path

---

## What to Value Most

When in doubt, prioritize:

1. reproducibility of local setup
2. quality of automation
3. sound Kubernetes and deployment thinking
4. clear configuration and secret handling
5. operational readiness and observability
6. code quality
7. bonus tooling last

A smaller, well-automated, well-explained submission should outrank a broader but fragile one.
