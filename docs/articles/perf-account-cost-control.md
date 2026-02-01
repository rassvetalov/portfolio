---
title: "Performance account cost control: warm-up/cool-down + watchdog + cost visibility"
---

# Performance account cost control: warm-up/cool-down + watchdog + cost visibility

Goal: keep expensive infrastructure at “full power” only during performance tests. The rest of the time it should automatically return to the **minimum viable state**, with clear rules and minimal console/kubectl heroics.

This is a pragmatic playbook for a dedicated `<perf account>` and `<perf clusters>`.

## 1) Context

- Perf testing is inherently bursty: heavy capacity is needed for hours, not weeks.
- Ownership can be blurry: some resources are IaC-managed, some are legacy/manual.
- Teams (dev/QA) should be able to run tests without waiting for platform engineers.

## 2) The problem we want to solve

- Overprovisioning becomes “sticky”: people scale up, forget to scale down.
- Mixed provisioning sources increase drift (Terraform/Terragrunt/manual).
- Without automation, you either pay too much or you break perf tests accidentally.

## 3) Approach: three layers

1. **Warm-up / Cool-down (self-service)**: explicit, team-triggered “scale up for test” and “scale down after test”.
2. **Watchdog (auto-cleanup)**: safety net for what teams forgot (or didn’t know they created).
3. **Cost monitoring**: dashboards and basic anomaly alerts for the `<perf account>` so you can connect actions to money.

## 3.1 Warm-up / Cool-down (self-service for dev/QA)

Provide a small toolbox (scripts/jobs) that operators can run:

- `warm-up`: switch AWS and Kubernetes resources to agreed perf profiles
- `cool-down`: revert to minimal profiles after the test

Typical targets (NDA-safe examples):

- AWS: `<autoscaling group>`, `<dynamodb table>`, `<elasticache>`, `<ebs volume>`
- Kubernetes: Deployments with HPA/KEDA ScaledObjects (reduce min replicas back to baseline)

Design rule: **all “big” scale-ups happen via approved tooling**, not via manual console clicks.

## 3.2 Watchdog layer (auto-cleanup)

### AWS resources (Cloud Custodian)

Use a Cloud Custodian deployment (e.g., chart + CronJobs) as a waist-control layer:

- discover candidates by “idle” signals
- mark resources for operations (`mark-for-op`)
- after grace period, apply remediation (resize/stop/delete) unless protected

Use an explicit protection tag, e.g. `keep=true`, for shared/special cases.

### Kubernetes resources (alerts + runbook → later automation)

Custodian is great for AWS resources, but not for Kubernetes metric-driven logic.
Start with:

- “overcapacity” alerts (e.g., very high min replicas with sustained low CPU)
- routing to the right team (via labels/ownership)
- on-call runs a runbook and triggers the cool-down tool

Later you can build a small service to automate the k8s side (see “Next improvements”).

## 3.3 Rules for teams (make it explicit)

1. Warm-up of large capacity in `<perf account>` is **only** via approved tooling.
2. Cool-down is mandatory after each perf test (part of the test checklist).
3. If a resource cannot be cooled down automatically, it must be explicitly protected (e.g., `keep=true`) or documented as an exception.
4. Any non-protected resource is a candidate for watchdog cleanup:
   - AWS: handled automatically by Custodian
   - Kubernetes: alerts + runbook (then automation)

## 4) Watchdog matrix (example)

Below is an NDA-safe example of how to document rules per resource type.
Keep the actual values owned by your team and easy to update.

### Auto Scaling Groups

- **Idle criteria**: desired/min ≥ 1 and low average CPU for a window
- **Action**: mark-for-op: resize → after grace period set desired/min to 0 (keep max unchanged)
- **Exclusions**: platform-managed node groups, `keep=true`, and `<prod>` environments

### DynamoDB (PROVISIONED)

- **Idle criteria**: provisioned billing mode and read/write consumed = 0 for a window
- **Action**: mark-for-op: update → reduce RCU/WCU to minimal safe values (e.g., 1/1)
- **Exclusions**: `keep=true`, `<prod>`

### ElastiCache (Redis / clusters)

- **Idle criteria**: low CPU for a window while status is healthy
- **Action**: mark-for-op: downsize → change node type to a minimal profile
- **Implementation note**: sometimes this needs a webhook/service because stock actions are limited
- **Exclusions**: `keep=true`, `<prod>`

### EBS (unattached)

- **Idle criteria**: unattached and older than an age threshold
- **Action**: mark-for-op: delete → delete volume (optionally snapshot first)
- **Exclusions**: `keep=true` and backup-related tags

### Kubernetes Deployments (manual phase)

- **Idle criteria (example)**:
  - min replicas (or minReplicaCount) is very high
  - sustained low CPU per pod over hours
  - stayed in this state for ~1 day
- **Action**: alert → on-call validates idleness → run `cool-down` to patch HPA/ScaledObject back to baseline
- **Exclusions**: active test window or explicit exceptions

## 5) Action plan

### Phase 1 (must-have)

- Define and publish the watchdog matrix (per resource type)
- Deploy Custodian in `<perf account>` aligned with the matrix
- Implement a minimal webhook/service for “hard” AWS operations (e.g., ElastiCache downsize) and call it from policies
- Add k8s “overcapacity” alerts and route them to the owning team
- Write the k8s overcapacity runbook (how to validate idle, how to trigger cool-down safely)
- Add minimal cost visibility:
  - daily/weekly cost dashboard for `<perf account>`
  - a simple anomaly/overspend alert

### Phase 2 (should-have)

- Build a small k8s “idle evaluator” service: evaluate metrics, patch HPA/ScaledObject, log changes, notify to Slack
- Add self-service workflows for test scenarios (warm-up/cool-down integrated into CI when ready)

### Phase 3 (could-have / target state)

- Integrate warm-up/cool-down into perf pipelines so environment “hydraulics” is automated
- Move remaining perf-critical resources into a single IaC source of truth
- Formalize perf profiles and minimal profiles per scenario/resource

## Navigation

- [Articles index](index)
- [Home](../index)

