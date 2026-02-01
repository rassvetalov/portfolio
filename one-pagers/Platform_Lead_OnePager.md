# Дмитрий Рассветалов

**Platform / DevOps Lead (AWS/EKS) · SRE**  
Limassol, Cyprus  
+357 99043151  |  vstahanov@gmail.com  

**Links:** [LinkedIn](https://linkedin.com/in/dmitriy-rassvetalov-92297458) · [GitHub](https://github.com/rassvetalov) · [OSS PR](https://github.com/electrolux-oss/aws-cost-exporter/pull/50)

## Summary
- Senior platform engineer with 20+ years in operations, networking and cloud.
- Recent scope: AWS + Kubernetes (EKS) platform spanning 30+ clusters (`<prod>/<stage>/<test>`).

## Highlights
- Service publishing via Cloudflare Zero Trust: access lead time 1–2 days → 1–2 hours; ~30% less manual work.
- Developer self-service provisioning (GitHub + Atlantis + Terraform modules): 1–2 days → 30–60 minutes; tickets -30–40%.
- FinOps automation for perf: Cloud Custodian in EKS (safe mark-for-op workflow); ~20–35% monthly savings.
- Observability: VictoriaMetrics/Prometheus/Grafana + guardrails (cardinality & heavy-query controls); triage ~20–25% faster, alert noise -20–30%.

## Selected projects
**EKS platform networking @ 30+ clusters** — Owned service exposure, DNS and ingress/egress patterns; integrated observability and operational standards.
**FinOps automation (Cloud Custodian + EKS + extensions)** — CronJobs daily/weekly → S3 reports + Slack; custom plugin for DynamoDB GSI throughput; webhook service for ElastiCache RG minimize/delete.
**Production observability and logging @ scale** — Graphite/Carbon (6 nodes, ~60TB) → VictoriaMetrics integration; Grafana HA (3 replicas, LDAP); Fluentd aggregator (50+ log types, 700+ routes, HPA 1–30).

## Tech stack
AWS (EKS, RDS Aurora, DynamoDB, Kinesis, S3, CloudFront, ElastiCache, OpenSearch, Route53, TGW) · Terraform/Terragrunt · Helm/Helmfile · ArgoCD · GitHub Actions · Atlantis · Prometheus/VictoriaMetrics/Grafana · Fluentd/Fluent Bit/Vector · Python/Go/Bash

## Leadership
Team Lead experience: managed 7 engineers (planning, prioritization, incident management, postmortems).
