# Case Study 04 — Observability Standards (VictoriaMetrics/Prometheus/Grafana)

## Context & scale

- **Platform scale**: 30+ EKS clusters across `<prod>/<stage>/<test>`
- **Signals**: metrics + alerting for platform and services, plus legacy metrics integration where required
- **Goal**: reduce alert noise and improve time-to-triage through standards and guardrails

## Problem

Without shared standards, observability becomes fragile and expensive:

- alert rules and dashboards are inconsistent across teams
- metric label cardinality grows unchecked (cost + query slowness)
- “heavy” queries degrade the whole system (shared backends)
- on-call spends too long correlating signals and finding owners

## Constraints / risks

- **Multi-tenant**: shared observability backends must protect against noisy neighbors
- **Scale variability**: `<prod>` and `<test>` have different requirements and risk tolerance
- **Cardinality traps**: labels like request IDs, user IDs, IPs, dynamic paths
- **Operational safety**: changes to alerting must be rolled out carefully to avoid blind spots
- **NDA safety**: no internal dashboards, org structure, or service names in public docs

## Design

Design goal: make the “right thing” easy and the “dangerous thing” visible.

Key components:

- **Prometheus / scrape layer**: consistent service discovery and scrape conventions per `<cluster>`
- **VictoriaMetrics (or compatible TSDB)**: centralized storage with guardrails for heavy queries
- **Grafana**: standardized folders, datasource patterns, alerting conventions
- **Standards**:
  - naming conventions for metrics and labels
  - recommended label sets for common workloads
  - alert rule templates with ownership metadata

Diagram reference (conceptual): you can reuse `../diagrams/finops-architecture.mmd` style for structure, but this case study focuses on practices rather than topology.

## Key implementation details

- **Standard dashboards/alerts**:
  - baseline dashboards for cluster health (control plane, nodes, workloads)
  - service template dashboards (latency, error rate, saturation)
  - alert rule patterns (paging vs ticket, severity, runbook link placeholders)
- **Cardinality control**:
  - identify high-cardinality labels and ban/transform them (where possible)
  - document “allowed labels” per metric family
  - educate teams with short examples and “why it hurts” guidance
- **Heavy query control**:
  - define guidance for query windows, step, max data points
  - detect suspicious queries and operationally handle them (warn → optimize → restrict if needed)
  - provide “safe defaults” in dashboards (time range, resolution)
- **Ownership & routing**:
  - require ownership tags/labels (team/service/env) in alert payloads
  - consistent alert annotations (summary, impact, next steps, runbook)

## Safety / operations

- **Rollout**:
  - introduce standards as templates first (opt-in)
  - migrate gradually, keep backward compatibility for critical alerts
  - measure alert noise and time-to-triage before/after
- **Monitoring**:
  - backend saturation (CPU/memory/IO)
  - query latency and error rates
  - cardinality indicators (series count trends)
- **Failure modes & handling**:
  - runaway cardinality → identify metric family/label, coordinate change, add protection
  - expensive dashboards → tune queries, limit range/resolution, split panels
  - alert floods → adjust thresholds, add dedup/grouping, validate signal

### NDA-safe example snippets

Anti-pattern vs pattern (illustrative only):

```text
BAD label: request_id=<uuid>  (high cardinality)
GOOD label: route=<normalized>, status_class=2xx/4xx/5xx
```

Alert annotation template:

```yaml
annotations:
  summary: "<signal> is above threshold on <cluster>"
  runbook: "<runbook-link>"
  owner: "<team-or-oncall-alias>"
```

## Results

- **Triage speed**: improved by **~20–25%** (range from resume)
- **Alert noise**: reduced by **~20–30%** (range from resume)

## What I would improve next

- Add automated linting for alerts/dashboards (style + ownership + forbidden labels)
- Expand “query cost” feedback loops to PR review (warn early)
- Improve onboarding docs with more “copy/paste safe” examples (still NDA-safe)

