---
title: "FinOps automation with Cloud Custodian on Kubernetes"
---

# FinOps automation with Cloud Custodian on Kubernetes

## Problem

Perf/non-prod environments accumulate idle resources. Manual cleanup is slow and inconsistent, and “delete” automation is risky without guardrails.

## Constraints (NDA-safe)

- Multi-`<account>` / multi-`<region>`
- Environment isolation: `<prod>` must not be impacted
- AWS API limits (throttling, eventual consistency)
- Need a safe remediation lifecycle (human reaction time)

## Approach (high level)

- Execute Cloud Custodian policies as Kubernetes CronJobs on a schedule
- Produce run reports in `<object storage>`
- Notify via `<queue> → mailer → Slack`
- Use a staged lifecycle: `mark-for-op → grace period → action`

## Implementation notes

- Policies grouped by risk: observe → mark → action
- Protection tag for opt-out (time-bounded preferred)
- Retries/backoff and rate limiting for sensitive APIs

## Results (ranges)

- ~20–35% monthly savings (perf environments)
- Fewer “forgotten” resources and less manual cleanup toil

## Next

- Add CI for policies (lint + fixtures + regression checks)
- Add PR-level cost awareness (estimation / budget hints)

