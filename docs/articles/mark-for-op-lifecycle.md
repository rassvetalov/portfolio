---
title: "Designing a safe mark-for-op lifecycle"
---

# Designing a safe mark-for-op lifecycle

## Why it matters

FinOps automation breaks trust if it deletes or downsizes resources unexpectedly. A safe lifecycle makes automation predictable and auditable.

## Lifecycle

`detect → mark → wait → act`

- **detect**: identify candidates (idle signals, age, unattached state)
- **mark**: tag/mark the resource with planned operation and timestamp
- **wait**: grace period to allow owners to react
- **act**: resize/stop/delete depending on policy risk level

## Guardrails

- dry-run first for new policies
- explicit environment scoping (`<test>/<perf>` by default)
- protection tags (opt-out)
- staged rollout: mark-only → action

## Ops notes

- Always produce artifacts: “what was evaluated” and “what would be changed”
- Treat AWS API throttling and partial failures as normal; keep runs idempotent

