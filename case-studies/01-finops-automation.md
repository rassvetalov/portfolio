# Case Study 01 — FinOps Automation (Cloud Custodian on EKS)

## Context & scale

- **Platform scale**: 29 EKS clusters across `<prod>/<stage>/<test>`
- **Target scope**: perf/non-prod workloads across multiple `<account>`/`<region>`
- **Goal**: reduce spend and operational load from idle resources, without breaking teams’ workflows

## Problem

Perf environments are high-churn: teams create infrastructure for load tests, experiments, and temporary services.
The result is predictable:

- idle resources linger after the work is done
- ownership is unclear when tags are missing or inconsistent
- manual cleanup is slow, risky, and hard to audit

## Constraints / risks

- **NDA / safety**: no “big red button” deletion without guardrails
- **Blast radius**: automation must not impact production workloads
- **False positives**: imperfect signals (CPU, request rate, traffic) can be misleading
- **AWS API limits**: throttling and eventual consistency
- **Human workflow**: teams need time to react before changes are applied

## Design

Architecture diagram: `../diagrams/finops-architecture.mmd`

High-level design:

- Cloud Custodian policies run as **EKS CronJobs** on a schedule (`daily`/`weekly`)
- Policies emit:
  - **reports** into `<object storage>` (for auditing and follow-up)
  - **notifications** via `<queue>` → mailer → Slack
- Remediation uses a safe lifecycle:
  - **mark-for-op** (tag/mark resource)
  - **grace period** (time to react)
  - **action** (resize/stop/delete)

## Key implementation details

- **Policy-as-code**:
  - policies grouped by risk level (warn/mark/action)
  - explicit allowlists for environments and resource types
  - consistent tagging strategy (`team`, `service`, `env`, `ttl` where available)
- **Automation targets (examples)**:
  - `<autoscaling group>` idle downscale (e.g., low CPU for a window)
  - `<dynamodb table>` idle downscale (0 read/write → minimal capacity)
  - `<elasticache replication group>` minimize (node type / replicas / shards)
  - `<ebs volume>` snapshot + delete if unattached for a window
- **Extensibility to close gaps**:
  - custom Cloud Custodian plugin for DynamoDB GSI throughput operations
  - webhook service for actions not supported natively (e.g., some ElastiCache RG operations)
- **Output & traceability**:
  - structured reports per run (resources evaluated, actions planned/executed, errors)
  - Slack messages include resource identity (generic), operation, and next step hints

## Safety / operations

- **Guardrails**:
  - dry-run mode for new policies and rollouts
  - protection tags (explicit opt-out)
  - environment scoping (`<perf>`/`<test>` only by default)
  - staged rollout: observe → mark-only → action
- **Reliability**:
  - retries/backoff for AWS APIs
  - rate limits for expensive or sensitive APIs
  - idempotent operations where possible
- **Monitoring**:
  - job success/failure metrics
  - action counters by policy
  - error budgets for “expected” failures (throttling, transient)
- **Failure modes & handling**:
  - AWS throttling → backoff + partial results
  - missing tags/ownership → warn/notify-only path
  - unexpected resource dependencies → skip + report

## Results

- **Cost savings**: **~20–35% per month** on perf environments (range from resume; varies by quarter and workload mix)
- **Operational impact**: fewer “forgotten” resources; less manual cleanup work
- **Safety**: changes are auditable, staged, and reversible in common scenarios (scale down vs delete)

## What I would improve next

- Add policy CI: unit tests for filters/actions and “golden” policy fixtures
- Improve ownership inference when tags are missing (still NDA-safe and controlled)
- Expand drift visibility: surface discrepancies between IaC and reality more proactively
- Add a lightweight “request exception” workflow (temporary opt-out with expiry)

