# Case Study 03 — Self-service Provisioning (GitHub + Atlantis + Terraform)

## Context & scale

- **Platform scale**: 29 EKS clusters across `<prod>/<stage>/<test>`
- **Consumers**: multiple engineering teams shipping services and internal tooling
- **Goal**: make infrastructure changes fast, reviewable, and safe at scale

## Problem

Ticket-driven provisioning does not scale:

- delivery time is typically **1–2 days** due to queueing and context switching
- changes are not consistently reviewed (or reviews are not “close to the code”)
- audit trails are fragmented (chat messages, tickets, ad-hoc scripts)
- repeated requests (DNS, queues, buckets, IAM bindings) create operational toil

## Constraints / risks

- **Safety**: prevent accidental destructive changes; keep blast radius small
- **Multi-environment**: `<prod>` differs from `<test>`; guardrails must be explicit
- **State & concurrency**: Terraform state locking, dependency ordering, parallel PRs
- **Drift**: real infra may diverge from declared state
- **NDA**: no internal identifiers in public docs

## Design

Workflow diagram: `../diagrams/atlantis-workflow.mmd`

Design choices:

- PR-driven workflow: **plan → review → apply**
- Terraform modules as a “contract” for consumers:
  - stable interfaces (`variables`, outputs)
  - opinionated defaults
  - built-in guardrails (naming, tagging, least privilege)
- Clear separation of responsibilities:
  - platform team owns modules and workflows
  - product teams own their declarative inputs per `<env>/<service>`

## Key implementation details

- **Atlantis workflow**:
  - automatic `plan` on PR, posted back to PR for review
  - apply only after approval (CODEOWNERS / required reviews)
  - scoped applies (only affected stacks)
- **Module library** (examples, NDA-safe):
  - networking primitives and DNS integration
  - managed databases (RDS/Aurora) with secrets management
  - queues/streams/object storage and required IAM bindings
  - monitoring checks (internal + external)
  - Zero Trust publishing primitives (apps/policies/DNS)
- **Guardrails**:
  - consistent naming conventions by `<env>/<service>/<instance>`
  - mandatory tagging for cost allocation and ownership
  - safe defaults for retention, encryption, logging
- **Drift control**:
  - periodic plans against mainline for selected stacks
  - runbooks for drift triage (detect → explain → reconcile)

## Safety / operations

- **Change control**:
  - reviews for high-risk modules or `<prod>` changes
  - explicit “break-glass” process (time-bounded, logged)
- **Failure modes & handling**:
  - plan/apply fails due to AWS limits → retry/backoff guidance + runbooks
  - state lock contention → documented unlocking procedure + prevention
  - partial apply → recovery runbooks and consistent naming to reduce ambiguity
- **Observability**:
  - pipeline signals: success/failure rates, time-to-merge, time-to-apply
  - basic cost visibility for common stacks (where safe and available)

## Results

- **Lead time**: typical requests completed in **~30–60 minutes vs 1–2 days**
- **Toil reduction**: routine DevOps tickets reduced by **~30–40%**
- **Auditability**: infra intent and changes are visible in PRs with immutable history

## What I would improve next

- Add automated cost estimation in PRs (budget awareness)
- Strengthen module documentation with minimal examples per module
- Expand drift detection coverage and add “drift severity” classification

