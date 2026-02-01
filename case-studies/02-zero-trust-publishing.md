# Case Study 02 — Zero Trust Service Publishing (Cloudflare Zero Trust)

## Context & scale

- **Platform scale**: 29 EKS clusters across `<prod>/<stage>/<test>`
- **Access pattern**: internal services that must remain private, but available to distributed teams
- **Goal**: reduce lead time and manual work for secure service access, without exposing services publicly

## Problem

Publishing internal services to users (developers, QA, analysts, SREs) was time-consuming:

- access requests took **1–2 business days**
- changes required manual steps and coordination
- policy consistency drifted over time
- audits were painful because intent and implementation diverged

## Constraints / risks

- **No public exposure**: services remain private; only authenticated/authorized users can reach them
- **Least privilege**: access should be scoped by role/group and environment
- **Auditability**: access rules must be reviewable and traceable
- **Operational simplicity**: onboarding new services must be repeatable
- **NDA safety**: no internal domains or identifiers in public artifacts

## Design

Flow diagram: `../diagrams/zero-trust-flow.mmd`

Design principles:

- Standardize “service publishing” as a platform capability:
  - `<service>` stays on private networking
  - users authenticate via `<IdP>`
  - Cloudflare Zero Trust enforces application policies
  - DNS is integrated as part of the publishing workflow
- Express the model as reusable IaC patterns (apps, policies, DNS records, connectors), parameterized by:
  - `<env>`, `<service>`, `<team>`, `<owner>`, `<risk-level>`

## Key implementation details

- **Policy model**:
  - default-deny posture
  - policies by environment and role/group
  - explicit “break-glass” path for incident response (time-bounded)
- **Standardization**:
  - naming conventions and labels for apps/policies
  - consistent health-check and ownership metadata
  - “known good” templates for common service types (HTTP, gRPC-over-HTTP, dashboards)
- **Automation**:
  - Terraform modules encapsulate Cloudflare ZT objects + DNS integration
  - PR review enforces change visibility and reduces ad-hoc exceptions
- **Observability**:
  - access logs for troubleshooting and audits
  - service-level health checks and basic SLO signals (availability/latency)

## Safety / operations

- **Rollout strategy**:
  - start with low-risk internal services
  - define guardrails (no public routes, explicit auth)
  - migrate service-by-service to avoid big-bang changes
- **Failure modes & handling**:
  - IdP outage → predefined emergency access procedure (minimal scope)
  - misconfigured policy → fast rollback through versioned IaC
  - DNS mismatch → automated checks + staged cutover
- **Runbooks**:
  - onboarding a new `<service>` into the ZT model
  - incident response: validate IdP, policy, connector status, service health

## Results

- **Lead time**: reduced from **1–2 business days to 1–2 hours** (range from resume; depends on service type and approvals)
- **Manual operations**: reduced by **~30%** via standard templates + IaC
- **Consistency**: access rules became reviewable, repeatable, and less prone to drift

## What I would improve next

- Add automated policy tests (static checks + integration smoke tests)
- Improve service catalog metadata so ownership and intent are always explicit
- Add “pre-approved patterns” library to speed up onboarding further

