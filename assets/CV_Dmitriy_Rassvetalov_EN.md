# Dmitriy Rassvetalov

**Platform / DevOps Lead · SRE**  
AWS · Kubernetes (EKS) · Terraform · Observability · FinOps automation  
Limassol, Cyprus · +357 99043151 · vstahanov@gmail.com  
LinkedIn: https://linkedin.com/in/dmitriy-rassvetalov-92297458  
GitHub: https://github.com/rassvetalov  
OSS PR: https://github.com/electrolux-oss/aws-cost-exporter/pull/50

> Public / NDA-safe: no internal domains/IDs/team names/topology/bucket names/VPC identifiers.

## Profile

DevOps/Platform engineer with **20+ years** in operations, networking, infrastructure, and cloud. Recent focus: **AWS**, **EKS**, **Terraform**, **CI/CD**, observability, reliability, and platform automation. Team leadership experience with strong ownership mindset.

**Scope:** a platform of **30+ EKS clusters** across `<prod>/<stage>/<test>` supporting services and internal products.

## Key achievements

- **EKS platform @ scale (30+ clusters):** owned platform networking and adjacent subsystems (service exposure, DNS, ingress/egress, observability integrations) across `<prod>/<stage>/<test>`.
- **Cloudflare Zero Trust service publishing:** designed and implemented a standardized access model (applications/policies + DNS integration). Reduced secure access lead time from **1–2 business days to 1–2 hours**, reduced manual operations by **~30%**.
- **Self-service provisioning (GitHub + Atlantis):** established a PR-driven provisioning model where engineers declare infrastructure and Atlantis applies Terraform changes. My contribution: production-ready Terraform modules for AWS and Cloudflare Zero Trust. Typical requests completed in **~30–60 minutes vs 1–2 days**, routine DevOps tickets reduced by **~30–40%**.
- **FinOps automation for perf environments:** implemented cost optimization using **Cloud Custodian** executed via **EKS CronJobs** (`daily/weekly`), with reports in object storage and Slack notifications via queue + mailer. Safety: **dry-run**, protection tags, and **`mark-for-op → grace period → action`** workflow. Savings: **~20–35% per month** (perf environments), fewer “forgotten” resources.
- **Custom tooling to close gaps:** delivered extensions where out-of-the-box tooling was insufficient (e.g., custom plugin for DynamoDB GSI throughput operations; webhook API on FastAPI for unsupported actions), with metrics, validation, and safe defaults.
- **Observability standards (VictoriaMetrics/Prometheus/Grafana):** centralized metrics, standardized dashboards/alerts, introduced cardinality limits and control of “heavy” queries. Result: faster triage (**~20–25%**) and less alert noise (**~20–30%**).
- **Open-source contribution:** improved cost metric export/filtering (PR link above); reporting preparation improved from **~1–2 hours to 15–30 minutes**.

## Experience

### Playrix Entertainment, LLC — Limassol, Cyprus

**Senior DevOps Engineer** · Oct 2022 — Present

- Owned networking and adjacent subsystems for an EKS platform of **30+ clusters** (`<prod>/<stage>/<test>`): service exposure, DNS, ingress/egress, observability integrations.
- Designed and rolled out Cloudflare Zero Trust service publishing with standardized patterns and operational practices; reduced access lead time to **1–2 hours**.
- Built self-service provisioning (GitHub + Atlantis): Terraform modules, validation, and a “contract” for engineers; typical provisioning **~30–60 minutes**.
- Improved observability (VictoriaMetrics/Prometheus/Grafana): standards, cardinality guardrails, heavy query control; reduced noise and improved incident triage.
- Implemented FinOps automation: Cloud Custodian workflows running in EKS with reports + notifications; added extensions (plugin + webhook) where required.
- Contributed to migration work (Nomad → EKS) as part of the team, focusing on networking and adjacent platform subsystems.

**IT Team Lead** · Nov 2021 — Oct 2022

- Managed a team of **7 engineers**: prioritization, planning, execution tracking, people development.
- Introduced planning cadence and transparent delivery practices; formalized incident management and post-incident reviews.

**Senior Network Administrator** · Nov 2020 — Nov 2021

- Developed hybrid corporate networking and remote access services.
- Increased repeatability through automation of network operations.

### NIKA LLC — Vologda, Russia

**Director / Head of IT Outsourcing** · Aug 2008 — Nov 2020

- Ran an IT services business (outsourcing/support), delivered **50+ projects** in automation and infrastructure; built an operations model (SLA, incidents, changes).

## Education

Vologda State Technical University — Automation Engineer · 2001

## Languages

- Russian — native
- English — fluent

