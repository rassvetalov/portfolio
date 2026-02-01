# Dmitriy Rassvetalov — Platform/DevOps Lead · SRE

AWS · Kubernetes (EKS) · Terraform · Observability · FinOps Automation

I build and operate AWS/EKS platforms at scale: **29 Kubernetes (EKS) clusters** across `<prod>/<stage>/<test>`.
My focus areas are **platform networking/service publishing**, **self-service infrastructure**, **observability**, and **FinOps automation**.
I also write **NDA-safe custom tooling** (exporters/services) to close gaps in AWS/monitoring ecosystems.

> NDA note: this repository is **public-friendly**. It uses placeholders like `<cluster>`, `<account>`, `<env>` and contains **no internal domains, IDs, bucket names, or topology details**.

## Scope

- **Scale**: 29 EKS clusters across `<prod>/<stage>/<test>`
- **Cloud**: AWS (multi-`<account>` / multi-`<region>`)
- **Platform**: EKS networking, ingress/egress, service exposure, DNS integration
- **IaC**: Terraform modules + PR-based workflows
- **Observability**: Prometheus/VictoriaMetrics/Grafana + legacy Graphite integration
- **FinOps**: automated downscale/cleanup for perf/non-prod environments with safety guardrails

## Selected projects

### 1) FinOps automation (Cloud Custodian in EKS)

- **Problem**: Perf/non-prod environments accumulate idle resources; manual cleanup is slow and inconsistent.
- **Approach**: Policy-as-code (Cloud Custodian) executed via EKS CronJobs, with **`mark-for-op → grace period → action`** lifecycle, reports in object storage, and Slack notifications via queue + mailer.
- **Result**: **~20–35% monthly cost reduction** in perf environments; fewer “forgotten” resources; safer operations via dry-run and protection tags.

### 2) Cloudflare Zero Trust service publishing

- **Problem**: Secure access to internal services required manual provisioning and long lead times.
- **Approach**: Standardized Zero Trust model (applications/policies + DNS integration) expressed as reusable IaC patterns.
- **Result**: Access lead time reduced from **1–2 business days to 1–2 hours**, manual operations reduced by **~30%**.

### 3) Self-service provisioning (GitHub + Atlantis)

- **Problem**: Infrastructure requests via tickets don’t scale; changes are hard to review/audit consistently.
- **Approach**: PR-driven Terraform workflow (plan → review → apply) with module library, guardrails, and drift awareness.
- **Result**: Typical requests completed in **~30–60 minutes vs 1–2 days**, routine DevOps tickets reduced by **~30–40%**.

## Technical artifacts

- Case studies:
  - `case-studies/01-finops-automation.md`
  - `case-studies/02-zero-trust-publishing.md`
  - `case-studies/03-self-service-provisioning.md`
- Diagrams (Mermaid):
  - `diagrams/finops-architecture.mmd`
  - `diagrams/zero-trust-flow.mmd`
  - `diagrams/atlantis-workflow.mmd`

## Links

- `links.md`
- Open-source: `https://github.com/electrolux-oss/aws-cost-exporter/pull/50`

