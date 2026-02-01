---
title: "Practical alert standards: routing, ownership, runbook-first"
---

# Practical alert standards: routing, ownership, runbook-first

Long story short: you can get to a **much healthier alerting system fast** without introducing SLOs everywhere and without changing your stack.

This article describes a pragmatic approach that works when:

- you already use **Grafana Alerting**
- you route notifications to **Slack** and optionally a paging tool (e.g. PagerDuty)
- you need **quick wins** (reduce noise, improve routing), not a large observability program

## 1) Problem

- One shared alert stream in Slack
- Too many non-actionable signals → alert fatigue
- Real incidents get lost in noise

### Constraints

- SLO/SLI coverage for all services is not realistic short-term (and not the current priority)
- We operate inside **Grafana Alerting** (no Prometheus Alertmanager assumption)
- We need a plan that is **fast to roll out** but still **effective**

## 2) Goals

1. Every alert has (or is moving towards having) a minimal routing label set:
   - `service`, `team`, `severity`, `environment`
   - sourced from metric labels where possible, otherwise set explicitly in the alert rule
2. Routing pipelines are clear and predictable:
   - `CRITICAL` → Grafana → paging high-urgency → Slack `#alerts-critical`
   - `WARNING` → Grafana → paging low/normal → Slack `#alerts-warning`
   - `INFO` → Grafana → Slack `#alerts-info` (no paging)
3. Naming and required labels are standardized across teams.

> NDA-safe note: channels and tools are shown as examples; use your equivalents.

## 3) Severity model

### 3.1 CRITICAL

`severity=CRITICAL` when:

- there is current or imminent **user impact**, for example:
  - key API/web endpoints are down or have high error rate/latency
  - database/cache is in a state where requests fail (or will fail predictably)
  - a platform component is broken (logging/metrics/ingress) in a way that creates active impact
- if this happens outside business hours, you **wake up on-call**

**Result / routing**

- Always page (high urgency) + post to `#alerts-critical`
- No “silent auto-resolve mindset”: every CRITICAL implies an incident or at least a concrete action item

### 3.2 WARNING

`severity=WARNING` when:

- there is degradation / early warning:
  - latency/error rate rising
  - CPU/memory/disk/IOPS trending up towards risk
  - partial infrastructure issues (restarts, missing replicas, partial unavailability)
- reaction is needed within **hours / next business day**, but not immediately

**Result / routing**

- Page low/normal urgency (optional, depending on team maturity) + `#alerts-warning`
- Auto-resolve enabled: when Grafana returns to OK, it sends RESOLVED; paging incident can be auto-closed

### 3.3 INFO

`severity=INFO` when:

- informational event
- does not require on-call reaction (useful for audit/troubleshooting/testing)

**Result / routing**

- Slack only: `#alerts-info`
- Auto-resolve on OK is fine

## 4) Alert standard: title, labels, notification text

This is a cross-team contract. Any new alert in Grafana Alerting should comply.

### 4.1 Title format

**Requirements**

- instantly shows *which service* and *what is wrong*
- consistent formatting across teams
- readable on mobile without expanding details

**Format**

`[<service>] <symptom/metric> (<context>)`

Where:

- `<service>`: logical service/component name (NDA-safe, no internal project codenames)
- `<symptom/metric>`: what exceeded the threshold (errors, latency, lag, saturation)
- `<context>`: time window (5m/10m) and/or qualifier (endpoint/topic/method/etc.)

**Bad**

- `[service] CPU high`
- `[service] Errors`
- `[service] Service down`

**Good (examples with placeholders)**

- `[checkout] HTTP 5xx > 5% (5m, /checkout/*)`
- `[auth] Latency p99 > 2s (10m, login)`
- `[cache] Evictions > 0 (5m)`

### 4.2 Required labels / annotations

Labels/annotations can come from metrics or from alert metadata. They are used for:

- routing (notification policies)
- filtering/grouping
- making Slack/paging messages self-contained

**Required**

- `service`: logical service/component name
- `severity`: `CRITICAL|WARNING|INFO`
- `team`: team or on-call group identifier

**Recommended**

- `environment`: `prod|stage|test|perf|...`
- `category`: `availability|performance|capacity|lifecycle|infra`
- `cluster` / `region` (only if it helps triage; keep NDA-safe)
- `runbook_url`: required for CRITICAL; recommended for important WARNING
- `dashboard_url`: strongly recommended for CRITICAL/WARNING

### 4.3 Notification message (Grafana annotation)

The title answers “what and which service”.
The message should be short and contain:

- severity and environment (if available)
- key numbers (what exactly is above threshold)
- links for diagnosis (dashboard/runbook)

**NDA-safe examples**

1) “Vector reached a tag `value_limit` (app={{ $labels.app }}, instance={{ $labels.instance }}) — some metrics are being dropped. Check cardinality and recent label changes.”

2) “Pod {{ $labels.pod }} in namespace {{ $labels.namespace }} is NotReady for >15m in cluster {{ $labels.cluster }}. Identify cause and restore readiness.”

3) “Memory usage >90% (current: {{ $values.B.Value }}%). Pod={{ $labels.pod }}, container={{ $labels.container }}. Check OOMKills/limits; adjust requests/limits or scale.”

4) “Pipeline {{ $labels.pipeline }} processed 0 events for 3 days. Validate health, errors, and upstream traffic.”

**Minimum requirements by severity**

- **CRITICAL**
  - title follows the format
  - required labels present
  - `dashboard_url` and `runbook_url` are mandatory
  - message should include `severity`, `environment`, `team` when possible
- **WARNING**
  - title follows the format
  - required labels present
  - `dashboard_url` recommended; `runbook_url` when feasible
- **INFO**
  - title follows the format
  - labels are recommended (`service`, `environment`, `team`)
  - links are optional

## 5) “Alert passport” (matrix) for critical services

For each critical service, create an alerting matrix:

Service: `<service>` (team: `<team>`)

**CRITICAL (max 1–3 per service)**

- `[<service>] HTTP 5xx > <x>% (5m)`
  - `dashboard_url=<...>`
  - `runbook_url=<...>`
- `[<service>] Latency p99 > <x>s (10m)`
  - `dashboard_url=<...>`
  - `runbook_url=<...>`

**WARNING**

- `[<service>] Latency p95 > <x>s (10m)`
- `[<service>] Error rate > <x>% (10m)`

**INFO**

- `[<service>] Rollout completed (deployment)`
- `[<service>] Autoscaling event (up/down)`

Rule of thumb:

- keep CRITICAL minimal (1–3)
- everything else is WARNING/INFO (or a candidate for removal)

## 6) Operational process (Slack-first)

Main alert work happens in Slack. To prevent alerts from becoming noise, the on-call engineer writes a **single-line decision** in the thread for CRITICAL/WARNING.

This achieves two things:

- we know whether reacting was worth it
- we decide what to change so the alert is better next time

### 6.1 When on-call must reply in a thread

- **CRITICAL**: always
- **WARNING**: ideally always; mandatory if:
  - it repeated/flapped 2+ times during the shift, or
  - you changed something (TUNE/SILENCE/DISABLE/RECLASS), or
  - it required real action (escalation/incident/task)
- **INFO**: do not comment; intervene only if it becomes noise

### 6.2 What to write (one line)

Format:

`<STATUS>:<DECISION>:<short note> [<task-link>] [<silence-link>]`

**STATUS (how we responded)**

- `ACTION`: actions/escalation/incident, or confirmed false positive/duplicate with evidence
- `NOACTION`: no action taken
- `REVIEW`: unclear; missing runbook; unclear impact → create a task for follow-up

**DECISION (what we do with the alert)**

- `KEEP`: keep as-is
- `RECLASS`: change severity (`CRITICAL↔WARNING↔INFO`)
- `TUNE`: adjust window/pending/threshold/aggregation/labels
- `SILENCE`: silence by labels/objects (time-bounded)
- `DISABLE`: disable/remove the rule

**Examples (NDA-safe)**

- `NOACTION:TUNE:Increase pending to 15m to reduce flapping`
- `REVIEW:KEEP:Unclear impact; add runbook and investigate (task link)`
- `NOACTION:DISABLE:Duplicate signal; keep only the symptom-level alert`
- `NOACTION:SILENCE:Maintenance window for <cluster> (silence link)`
- `ACTION:KEEP:Scaled the service; verified error rate recovered (incident link)`

### 6.3 Fast fixes when tuning

- **Flapping**: increase pending/window, raise threshold, smooth the metric
- **Flood**: remove `pod/instance/container` from labels, aggregate to `service/namespace/cluster`
- **Duplicates**: keep one “symptom” alert; silence/disable the rest
- **Wrong signal**: keep CPU/memory as WARNING/INFO; impact signals (latency/5xx/down) are CRITICAL
- **Missing metadata**: add at least `service` + `severity`; ideally `team` + `environment`

### 6.4 Weekly/bi-weekly hygiene (30-minute task)

Once per sprint, rotate a short maintenance task:

- review the top noisy alerts (critical/warning/info) for the last week
- apply decisions: KEEP/TUNE/RECLASS/SILENCE/DISABLE

Targets:

- CRITICAL: almost all → ACTION
- WARNING: minimal flapping and repeats without value
- INFO: channel should not become a trash bin; noisy → silence/disable, meaningful → reclassify to WARNING

## Navigation

- [Articles index](index)
- [Home](../index)
## Navigation

- [Articles index](index)
- [Home](../index)

