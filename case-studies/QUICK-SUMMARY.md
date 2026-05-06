# Victoria Metrics Multi-AZ Architecture — Quick Summary

**Created:** May 2026  
**Total content:** ~1,600 lines across 4 documents  
**Audience:** Platform engineers, SRE leads, DevOps architects, on-call teams

---

## 📚 What You Just Read

Three in-depth technical articles + one reader's guide on how we built a cost-optimized, highly available Victoria Metrics infrastructure across AWS availability zones.

### The Story

**Before:** RF=2 replication cost 2× storage/I/O. vmselect fanned out queries across 20 vmstorage nodes in 3 AZ → $900/month cross-AZ egress. No zone awareness in hashing → AZ failure risked data loss.

**After:** Two independent clusters (VM-A in 1a, VM-B in 1b), each RF=1, 100% data replication via vmagent dual-write at application layer. vmselect queries local 10 nodes only → 0 cross-AZ read traffic. Cost: **−$1,630/month** (accounting for dual-write overhead). DR: **RPO=0 at AZ level.**

---

## 📖 The Four Documents

| Document | Lines | Purpose | Read Time |
|----------|-------|---------|-----------|
| [README-victoria-metrics-series.md](./README-victoria-metrics-series.md) | 202 | Index, overview, reading order | 3 min |
| [victoria-metrics-multiaz-isolation.md](./victoria-metrics-multiaz-isolation.md) | 355 | Architecture design, why dual-cluster beats zone-aware sharding | 8 min |
| [prometheus-scraper-locality.md](./prometheus-scraper-locality.md) | 441 | Zone-aware scraper architecture (complementary optimization, deferred) | 10 min |
| [victoria-metrics-technical-reference.md](./victoria-metrics-technical-reference.md) | 574 | Configs, runbooks, diagrams, checklists (reference material) | 12 min |

---

## 🎯 Key Insights

### 1. Why Dual-Cluster Beats Zone-Aware Sharding

**Problem with zone-aware consistent hash:**
```
Target T in AZ-A
  hash(T) % 15 = shard-12 (physically in AZ-C)
  shard-12 has relabel rule: keep zone=AZ-C
  T.zone = AZ-A → drop
  Result: blind spot, no shard owns T
```

**Our solution: Independent CRD clusters**
```
Target T in AZ-A
  All 3 VMAgent CRDs see T during service discovery
  
  In AZ-A cluster:
    relabel keep zone=AZ-A → pass
    hash(T) % 5 → shard-2 → scrape ✓
  
  In AZ-B cluster:
    relabel keep zone=AZ-B → drop (before sharding)
  
  In AZ-C cluster:
    relabel keep zone=AZ-C → drop
```

No blind spots. Relabeling happens per-CRD before sharding.

### 2. Topology-Mode: Auto — Kubernetes Native Affinity

Standard Service spreads endpoints evenly across all AZ.  
With `topology-mode: Auto`: kube-proxy routes only to local-AZ endpoints (via iptables).  
Fallback: if local AZ has 0 endpoints, kube-proxy uses other AZ (soft isolation, not hard).

**Silent deactivation risk:** If endpoint distribution skews >3× from node distribution, kube-proxy disables hints **without alerts**. AWS billing still shows cross-AZ traffic. Mitigation: monitoring alert.

### 3. Application-Layer Dual-Write Is Simpler Than Storage-Layer Replication

**RF=2 via vmstorage replication:**
- Complex: zone-aware sharding + replication sequencing
- Risky: both replicas can land in same AZ (issue #4216)
- Inflexible: write buffer lost if primary ingester fails (issue #8044)

**Dual-write at vmagent:**
- Simple: two independent remoteWrite URLs
- Resilient: bulkhead pattern (isolated queues per URL)
- Recoverable: 50GB disk buffer per pod = ~5 days failover window

Trade-off: +$950/month cross-AZ write overhead (acceptable vs. operational simplicity).

### 4. $1K/Month ROI Threshold for Scraper Locality

Baseline measurement (7 clusters, May 2026): $534/month cross-AZ scrape.  
Zone-aware scraper design could save ~$373/month.  
But operational overhead (N VMAgent CRD, chart upgrade, per-cluster rollout) ≈ $5-10K one-time.  

**Breakeven:** 3 months. But since no single cluster exceeds $1K/month, we deferred. Design frozen—ready to activate when threshold hits (estimated 4-6× traffic growth, likely 2027).

---

## 🛠️ For Different Roles

### Platform Lead / Architect

1. Read: [victoria-metrics-multiaz-isolation.md](./victoria-metrics-multiaz-isolation.md)
2. Reference: Design decisions table + cost analysis
3. Takeaway: Dual-cluster = simpler + safer than zone-aware hashing

### On-Call Engineer

1. Quick-read: [victoria-metrics-technical-reference.md](./victoria-metrics-technical-reference.md) — failover section
2. Reference: Verification checklist
3. Bookmark: Runbooks section + alert thresholds

### DevOps Implementing the Design

1. Read: [victoria-metrics-technical-reference.md](./victoria-metrics-technical-reference.md) — configs, affinity rules, NLB setup
2. Reference: Karpenter NodePool config (copy-paste ready)
3. Follow: Migration runbook in itprod-docker

### FinOps / Cost Analyst

1. Read: [prometheus-scraper-locality.md](./prometheus-scraper-locality.md) — baseline measurement
2. Reference: Cost breakdown table
3. Understand: Why $1K/month threshold + when to re-evaluate

---

## 📊 Numbers at a Glance

| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| **vmselect fan-out** | 20 vmstorage across 3 AZ | 10 per cluster | −50% memory |
| **Read-path cross-AZ** | ~3 hops per query | 0 hops | −$900/mo |
| **Write I/O per cluster** | 2× samples/sec (RF=2) | 1× (RF=1) | −$400/mo |
| **Dual-write overhead** | — | +$950/mo | +$950/mo |
| **Net cost delta** | — | — | **−$1,630/mo** |
| **DR (AZ failure)** | RPO=partial, RTO=recovery var | RPO=0, RTO=~20s | ✅ Improved |

---

## ✅ Design Status

| Aspect | Status | Notes |
|--------|--------|-------|
| **Multi-AZ dual-cluster (Victoria Metrics)** | ✅ Deployed | Production (Jan 2026), all clusters |
| **Karpenter NodePools (AZ-pinned)** | ✅ Deployed | EBS volumes guaranteed per AZ |
| **NLB (L4, no cross-zone)** | ✅ Deployed | Replaced nginx Ingress + vmauth |
| **Scraper locality (VMAgent zone-aware)** | ⏸️ Deferred | Design frozen, ROI threshold not met |

---

## 🚀 Next Steps

1. **For new clusters:** Use multi-AZ template (Karpenter + NLB + dual-write)
2. **Cost monitoring:** Quarterly check on cross-AZ scrape cost per cluster
3. **Scraper activation trigger:** When any cluster hits $1K/month baseline
4. **Operational readiness:** Train on-call on failover sequence (Tech Ref §Failover)

---

## 📖 Recommended Reading Order

**5-minute executive summary:**
1. This document (you're reading it)
2. [README-victoria-metrics-series.md](./README-victoria-metrics-series.md) — overview

**Deep technical dive (30 minutes):**
1. [victoria-metrics-multiaz-isolation.md](./victoria-metrics-multiaz-isolation.md) — architecture
2. [victoria-metrics-technical-reference.md](./victoria-metrics-technical-reference.md) — hands-on configs

**Scraper optimization (optional, for cost-conscious teams):**
- [prometheus-scraper-locality.md](./prometheus-scraper-locality.md) — understand design, ROI threshold

**On-call preparation (10 minutes):**
1. [victoria-metrics-technical-reference.md](./victoria-metrics-technical-reference.md) — Failover section
2. Bookmark the Verification Checklist

---

## 🔗 Related Resources

**In this repo:**
- `itprod-docker/victoria-metrics-cluster/README.md` — cluster topology baseline
- `itprod-docker/victoria-metrics-cluster/SCRAPER-AZ-LOCALITY.md` — scraper design source document
- `itprod-docker/AGENTS.md` — operational runbooks

**Upstream:**
- [VictoriaMetrics Multi-AZ Architectures](https://docs.victoriametrics.com/guides/vm-architectures/#multi-cluster-and-multi-az)
- [Kubernetes Topology-Aware Routing](https://kubernetes.io/docs/concepts/services-networking/topology-aware-routing/)
- [AWS NLB Cross-Zone Load Balancing](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/network-load-balancers.html#cross-zone-load-balancing)

---

## 👤 Author

**Dmitrii Rassvetalov**  
SRE / Platform Engineering  
Playrix IT Production  
May 2026

**Questions?** Open an issue or contact the IT Production team.
