---
title: "PR-driven IaC with Atlantis: guardrails, approvals, drift workflows"
---

# PR-driven IaC with Atlantis: guardrails, approvals, drift workflows

## Problem

Ticket-driven provisioning is slow and hard to audit. Ad-hoc changes drift over time and increase operational risk.

## Workflow (draft)

- PR opened → Atlantis runs `plan` and comments results
- Review gates (CODEOWNERS / required approvals)
- Apply only after approvals and explicit action
- Drift awareness via scheduled plans + runbooks

## Results (ranges)

- Typical requests: ~30–60 minutes vs 1–2 days
- Routine DevOps tickets: -30–40%

## TODO (expand this article)

- [ ] Add guardrails (CODEOWNERS, approvals, environment scoping)
- [ ] Add state locking/concurrency notes and runbooks
- [ ] Add drift handling (detect → explain → reconcile)
- [ ] Add an NDA-safe repo layout example

## Navigation

- [Articles index](index)
- [Home](../index)

