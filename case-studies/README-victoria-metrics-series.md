# Victoria Metrics Multi-AZ Architecture Series

This series documents the design and implementation of a highly available, cost-optimized Victoria Metrics monitoring infrastructure spanning multiple AWS availability zones.

---

## 📋 Overview

**Problem:** RF=2 replication doubled storage costs without providing AZ-level disaster recovery. Prometheus scraping traffic scattered across AZ incurred unnecessary egress charges.

**Solution:** Dual independent VM clusters (RF=1 per cluster, 100% data replication via application-layer dual-write) + zone-aware scraper architecture.

**Results:**
- Eliminated vmselect cross-AZ fan-out: **−50% memory pressure**
- Reduced read-path egress: **−$900/month**
- Dual-write overhead: **+$950/month**
- **Net savings: ~$1,630/month** (−8% of monitoring budget)
- **DR: RPO=0 at AZ level**

---

## 📚 Articles in This Series

### 1. [Multi-AZ Victoria Metrics Cluster: Architecture for DR Without Replication Tax](./victoria-metrics-multiaz-isolation.md)

**Audience:** Platform engineers, SRE leads, architecture reviewers  
**Length:** ~8 min read  
**Key sections:**
- Why RF=2 fails at AZ level (3 gaps analyzed)
- Dual-cluster design with local-first affinity
- Kubernetes `topology-mode: Auto` for automatic routing
- NLB configuration (L4, no buffering, no vmauth tax)
- Cost analysis and trade-offs
- Failover sequence and recovery

**Takeaway:** Dual independent clusters > zone-aware sharding. Architectural simplicity + operational safety.

---

### 2. [Scraper Locality: How We Cut Cross-AZ Prometheus Metrics Traffic by 70%](./prometheus-scraper-locality.md)

**Audience:** DevOps engineers, metrics platform teams, cost-conscious ops  
**Length:** ~10 min read  
**Key sections:**
- Baseline measurement: $534/month cross-AZ scrape across 7 clusters
- Why naive per-shard relabeling creates blind spots
- Zone-aware architecture: N VMAgent CRD per AZ
- T-shirt sizing presets (s/m/l/xl)
- Edge cases: apiserver, Pending pods, VMProbe
- Implementation phases with ROI gate: $1K/month threshold

**Takeaway:** Cost-effective only above $1K/month per cluster. Design frozen, ready to activate. Currently deferred on all clusters.

---

### 3. [Technical Reference: Victoria Metrics Multi-AZ Architecture](./victoria-metrics-technical-reference.md)

**Audience:** On-call engineers, incident responders, implementation teams  
**Length:** ~12 min read (reference material)  
**Key sections:**
- Architecture diagrams (write path, read path, failover)
- Karpenter NodePool config with AZ pinning
- Pod affinity rules (strict for storage, preferred for compute)
- Kubernetes Service topology-mode Auto deep-dive
- NLB configuration (cross_zone_load_balancing=false)
- VM component flags (per-role)
- EBS tuning for compaction (6K IOPS, 500 MB/s)
- Verification checklist (post-migration)
- Cost breakdown by component

**Takeaway:** Concrete configurations, copy-paste ready. First reference when deploying or troubleshooting.

---

## 🏗️ Design Decisions

| Decision | Rationale | Trade-Off |
|----------|-----------|-----------|
| **RF=1 per cluster** | Eliminates write-I/O doubling; removes hash blindness | Requires dual-write at application layer |
| **Dual-write at vmagent** | Simple, retryable, disk-buffered (5-day retention) | +$950/month cross-AZ traffic overhead |
| **NLB instead of nginx+vmauth** | L4 = no buffering, better latency; L7 adds write path tax | TCP idle timeout 350s (hardcoded) |
| **topology-mode: Auto** | Automatic locality, kube-proxy native, no custom ingress | Silent deactivation risk (requires monitoring) |
| **Karpenter WhenEmpty only** | Prevents unacceptable pod evictions on RF=1 storage | Doesn't consolidate nodes as aggressively |
| **Scraper locality deferred** | Design complete, but $1K/month threshold not met org-wide | Must re-evaluate when any cluster crosses threshold |

---

## 📊 Metrics & Monitoring

### Key Alerts

```promql
# Topology hints deactivated (cross-AZ traffic returned silently)
kube_endpointslices_annotations{...topology_mode="Auto"} 
  unless on(endpointslice) 
kube_endpointslices_annotations{...hints_auto="yes"}

# Write buffer filling up (data loss risk)
vmagent_remotewrite_pending_data_bytes / (200 * 1024^3) > 0.7

# Partial responses (vmstorage node unavailable)
increase(vm_partial_results_total[5m]) > 0

# Cross-AZ traffic not optimized
sum(rate(container_network_transmit_bytes_total{pod=~"vmagent.*"}[5m])) 
  > (1.5 * historical_baseline)
```

### Baseline Measurements

- **Topology hints silent deactivation:** Endpoint skew >3× vs. node distribution
- **RF=1 partial response window:** ~60s per vmstorage node rolling restart
- **Dual-write disk buffer:** 50GB × 3 pods = ~5 days at failover throughput
- **NLB failover latency:** ~20s (health check interval)
- **Cross-AZ scrape cost:** $1K/month = activation threshold

---

## 🔄 Implementation Status

| Component | Status | Cluster | Notes |
|-----------|--------|---------|-------|
| **Dual-cluster (VM-A/B)** | ✅ Production | atf01, prf01, apc01 | Deployed Jan 2026 |
| **Scraper locality** | ⏸️ Deferred | All | ROI threshold not met; design frozen |
| **Karpenter NodePools (AZ-pinned)** | ✅ Production | All | victoriametrics-storage-az-a/b |
| **topology-mode: Auto** | ✅ Production | All | K8s 1.27+ |
| **NLB (write/read/export)** | ✅ Production | All | Removed nginx Ingress |

---

## 🚀 Related Designs

- **Victoria Metrics Cluster Topology** — Single-cluster baseline (in itprod-docker README)
- **VMAgent Buffer Architecture** — Write-path resilience (separate design doc)
- **Karpenter Integration** — NodePool patterns across Playrix (itprod-provisioning)

---

## 📖 Reading Order

**For architects:**
1. Start: victoria-metrics-multiaz-isolation.md (understand problem/solution)
2. Compare: scraper-locality.md (complementary cost optimization)
3. Reference: technical-reference.md (deployment details)

**For on-call engineers:**
1. Start: technical-reference.md (current state, dashboards, alerts)
2. Troubleshoot: multiaz-isolation.md (failover section)
3. Cost insight: scraper-locality.md (why it's deferred)

**For new team members:**
1. Start: multiaz-isolation.md (big picture)
2. Deep-dive: technical-reference.md (hands-on)
3. Future optimization: scraper-locality.md (roadmap)

---

## 🔍 Open Questions & Future Work

| Question | Trigger | Owner | Timeline |
|----------|---------|-------|----------|
| **Re-trigger scraper locality** | Any cluster cross-AZ scrape ≥$1K/month | Metrics platform team | Quarterly review |
| **Capacity event → VM pod can't start** | Node provisioning lag >5 min | SRE oncall | Rolling incident analysis |
| **Catch-all VMAgent overloaded** | CPU/memory >80% or targets_skipped grows | Metrics platform | Post-phase-6 measurement |
| **Backfill speed validation** | Before full historical data migration | Data platform | vmctl concurrency tuning |

---

## 🛠️ Operational Runbooks

- **Scale vmstorage disk (2Ti → 4Ti):** `../runbooks/vmstorage-volume-expand-to-2Ti.md`
- **Migrate RF=2 to dual-cluster:** `../victoria-metrics-cluster-stage/TODO-prod-migration.md`
- **On-call playbook:** `../docs/incidents/vm-cluster-outage.md` (link)

---

## 📝 References

**Upstream documentation:**
- [Victoria Metrics Multi-AZ Topologies](https://docs.victoriametrics.com/guides/vm-architectures/#multi-cluster-and-multi-az)
- [Kubernetes Topology-Aware Routing (KEP-2433)](https://kubernetes.io/docs/concepts/services-networking/topology-aware-routing/)
- [AWS NLB Cross-Zone Load Balancing](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/network-load-balancers.html#cross-zone-load-balancing)

**GitHub issues:**
- [VictoriaMetrics #4216](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/4216) — Zone awareness in consistent hash
- [VictoriaMetrics #8044](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/8044) — Write buffer lost on ingester failure
- [vm-operator #604](https://github.com/VictoriaMetrics/operator/issues/604) — replicaCount duplication

**Prior art:**
- [Vijay Gupta — $10K/year savings via zone-aware vmagent (Oct 2025)](https://medium.com/@vijayrauniyar1818/how-we-eliminated-10k-year-in-aws-cross-zone-data-transfer-costs-with-zone-aware-kubernetes-09fff0c2435b)
- [Tanmay Bhat — Zonekeeper controller (Jan 2025)](https://tanmay-bhat.github.io/posts/zonekeeper/)

---

## 📧 Author

**Dmitrii Rassvetalov**  
*SRE / Platform Engineering*  
Playrix IT Production  
May 2026

**Questions?** Open an issue in the portfolio repo or contact the IT Production team.
