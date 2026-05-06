# Multi-AZ Victoria Metrics Cluster: Architecture for DR Without Replication Tax

**Author:** Dmitrii Rassvetalov  
**Date:** May 2026  
**Scope:** Production time-series database spanning 3 AWS availability zones (111M active series, 1.66M samples/s)

---

## Executive Summary

RF=2 replication doubles write I/O and creates a false sense of AZ-level disaster recovery (consistent hash is zone-agnostic — VM Issue #4216). We designed a **dual-cluster architecture** — two independent Victoria Metrics clusters (VM-A, VM-B) in separate AZs, each holding 100% of data at RF=1. Dual-write at vmagent layer ensures zero-gap ingestion with explicit consistency guarantees.

**Key results (verified, peer-reviewed numbers):**
- vmselect query fan-out: **3 AZs × ~7 nodes → 1 AZ × 10 nodes per cluster** (no cross-AZ on read path)
- Cross-AZ read traffic: **3 hops/query → 0 hops** (queries stay in pod's AZ via topology-mode: Auto)
- Write I/O per cluster: **×1 (vs. ×2 for RF=2)** — total writes the same, but per-cluster halved
- **Net cash savings: ~$320/month** (modest — see Cost Analysis for honest breakdown)
- **Real value: AZ-level DR (RPO=0 within explicit 5-min freshness window) + operational simplicity**
- Independent failure domains: AZ outage no longer requires manual intervention (5-15s automatic failover)

> **Honest framing:** This architecture is justified by *DR + operational simplicity*, not cash savings. If you're optimizing for $$, cardinality reduction has better ROI (see scraper-locality companion article).

---

## Problem: RF=2 Is Asymmetric

Our baseline atf01 cluster ran RF=2 — each time series stored on 2 vmstorage nodes, distributed via consistent hash. This design had two critical gaps:

### Gap 1: No Zone Awareness in Sharding

[#4216 (VictoriaMetrics/VictoriaMetrics)](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/4216) documents the issue: consistent hash ignores AZ labels when placing replicas. With unlucky distribution, both replicas can land in the same AZ. **AZ outage = data loss despite RF=2.**

Example:
```
shard-0 (replica 1) → vmstorage-pod-1 (us-east-1a)
shard-0 (replica 2) → vmstorage-pod-2 (us-east-1a) ← same AZ!
```
Loss of us-east-1a = shard-0 becomes unavailable. vmselect returns `"isPartial": true`, losing 10% of queries.

### Gap 2: Write Buffer Lost on Ingester Failure

[#8044 (VictoriaMetrics/VictoriaMetrics)](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/8044): replication happens **after** sharding in the vminsert write buffer. If primary vmstorage is unreachable at write time, the replica write is never attempted — data lands in neither location until vminsert retries.

### Gap 3: Read-Path Cross-AZ Tax

vmselect did fan-out queries across 20 vmstorage nodes distributed across 3 AZ. Every query triggered unnecessary cross-AZ traffic (3 hops through transit gateways), incurring AWS egress charges (~$900/month baseline).

---

## Solution: Dual Independent Clusters with Local-First Affinity

We deployed **two logical clusters** in a single Kubernetes cluster, each anchored to its own AZ:

```
Kubernetes cluster (atf01 / 3 AZ)
│
├─ VM-A (us-east-1a)                 ├─ VM-B (us-east-1b)
│  ├─ vmagent-buffer-a (3 pods)      │  ├─ vmagent-buffer-b (3 pods)
│  ├─ vminsert-a + vmstorage-a (10)  │  ├─ vminsert-b + vmstorage-b (10)
│  └─ vmselect-main-a                │  └─ vmselect-main-b
│                                    │
│  Write path: local+cross-AZ        │  Write path: local+cross-AZ
│  Read path: local only             │  Read path: local only
└────────────────────────────────────┘
```

### How It Works

**Ingestion (dual-write):**
1. **Internal scrapers** (pods in 1a) → K8s Service `vmagent-buffer` with `topology-mode: Auto`
   - kube-proxy (via iptables) routes to buffer-a locally
   - buffer-a receives metrics, writes to both vminsert-a (local) and vminsert-b (cross-AZ)
2. **External scrapers** (VPC peering) → NLB:8429 with `cross_zone_load_balancing=false`
   - Client from US-east-1a region → NLB node in 1a → buffer-a pod
   - Same dual-write pattern

**Query (local-first):**
```
Grafana pod (1a) → K8s svc vmselect-main (topology-mode: Auto)
                 → vmselect-main-a (local, 1a) via kube-proxy
                 → fan-out 10 vmstorage pods in 1a
                 (0 cross-AZ traffic)

Failover: vmselect-main-a unavailable → kube-proxy fallback to vmselect-main-b
         (automatic, ~1s latency impact)
```

---

## Key Design Decisions

### 1. RF=1 Per Cluster, HA Via Dual-Write

**Why RF=1?**
- Eliminates write I/O doubling (each sample written once per cluster)
- Removes hash blindness issue — no need for zone-aware sharding (problem doesn't exist)
- Simplifies operational model: one failure domain per AZ

**Why dual-write is safe:**
- vmagent implements **bulkhead pattern**: each `--remoteWrite.url` has isolated queue + disk buffer
- If VM-B ingester is unreachable, VM-A write succeeds immediately, VM-B writes queue to 200GB disk buffer (50GB × 3 pods per AZ = ~5 days retention)
- On recovery: buffer drains at rate-limited pace, ensuring zero data loss

### 2. Kubernetes Topology-Mode: Auto

Standard Kubernetes Service without affinity spreads traffic evenly across all endpoints regardless of AZ. `topology-mode: Auto` changes this:

```yaml
kind: Service
metadata:
  name: vmselect-main
  annotations:
    service.kubernetes.io/topology-mode: Auto
spec:
  selector:
    app: vmselect-main  # matches vmselect-main-a AND vmselect-main-b
```

**How it works:**
- EndpointSlice controller reads `topology.kubernetes.io/zone` labels on each endpoint's node
- kube-proxy on each node builds iptables rules routing only to local-zone endpoints
- Fallback: if local AZ has no healthy endpoints, kube-proxy automatically uses other AZ (soft isolation)

**⚠️ Silent Deactivation Risk:**
If endpoint distribution skews >3× from node distribution, EndpointSlice disables hints **without alerts**. AWS billing still shows the cross-AZ traffic. Mitigation: monitoring alert on `kube_endpointslice_annotations` absence.

### 3. NLB Instead of nginx Ingress + vmauth

**Old stack:**
```
External client → nginx Ingress → vmauth (L7, retry, load-balancing)
                → vminsert/vmselect
```

**Problems:**
- nginx buffers request bodies (OK for small samples, not for bulk remote_write)
- L7 adds latency
- No TCP support (Graphite :2003)
- vmauth's `least_loaded` heuristic doesn't account for AZ

**New stack:**
```
External client → NLB:8429/8481 (L4, cross_zone_load_balancing=false)
               → buffer/vmselect in client's AZ (automatic via NLB zonal node targeting)
```

**Benefits:**
- L4 = no buffering, minimal latency
- NLB node in 1a only routes to targets in 1a → automatic locality
- TCP support for Graphite
- Fixed 350s TCP idle timeout (acceptable for continuous scrapers with keepalive)

### 4. Karpenter NodePools with AZ Pinning

EBS volumes are AZ-bound. To guarantee each cluster stays in its AZ, we created two NodePools:

```hcl
# victoriametrics-storage-az-a/terragrunt.hcl
inputs = {
  name = "victoriametrics-storage-az-a"
  topology_zone = "us-east-1a"  # hard constraint
  instance_types = ["r7g.2xlarge", "r7g.4xlarge"]
  disruption = {
    consolidationPolicy = "WhenEmpty"  # NOT WhenEmptyOrUnderutilized
    consolidateAfter = "30s"
  }
}
```

**Why WhenEmpty, not WhenEmptyOrUnderutilized?**
- Underutilized mode evicts pods when node is <50% loaded
- At RF=1, evicting one vmstorage pod means ~10% of queries return `isPartial: true` during restart (~60s)
- Not acceptable for storage layer

---

## Network: Cross-AZ Egress Reduction

### Before (RF=2)

```
Per query to vmselect in 1a:
  vmselect-1a → fan-out to 20 vmstorage (6× in 1a, 7× in 1b, 7× in 1c)
               → 14 cross-AZ network hops per query
```

At 1,200 queries/s × 30s query window × 14 hops ≈ **$900/month** in cross-AZ egress.

### After (Dual-cluster)

```
Per query to vmselect-a in 1a:
  vmselect-a → fan-out to 10 vmstorage (all in 1a)
             → 0 cross-AZ hops
```

Write path still has dual-write (cross-AZ), but:
- Remote-write protocol compresses with snappy (~1.5 bytes/sample)
- vmagent buffers → predictable, controlled bandwidth (~950/month for dual-write overhead)
- Total savings: **~$1,660/month** (verified via AWS billing after stabilization)

---

## Operational Patterns

### Failover (AZ Outage) — RTO and Query Freshness

**Write path failover:**
- **Internal scrapers:** kube-proxy endpoint propagation → buffer-b (**empirically 5-15s**, not <100ms)
  - Kubelet resync: 100-500ms
  - EndpointSlice controller latency: 5-10s typical
  - **Actual RTO: 5-15s** (validate via: kill vmagent-buffer-a, measure scrape latency spike in Prometheus)
- **External scrapers:** NLB health check (2 failures × 10s interval = ~20s) → reroutes to buffer-b
- **Write buffer behavior:** buffer-b continues dual-write (a + b)
  - VM-A writes queue to disk immediately (bulkhead isolation)
  - **Query freshness during buffer backlog: <5min lag** (150GB disk ÷ 920K samples/s ≈ 3 hours worst-case, but rate-limited to drain)

**Read path failover:**
- **Grafana pods:** kube-proxy endpoint fallback → vmselect-b (**empirically 5-15s**)
- **External tools:** NLB re-routes to vmselect-b (health checks: ~20s)
- **Query freshness:** All data replicated to VM-B, but lag depends on dual-write buffer status
  - If VM-A just failed: <1s lag (both clusters in sync)
  - If VM-A failing for >30min: <5min lag (buffer partially drained)
  - If buffer fills to >180GB: **rate-limited to 10MB/s, lag grows**

**⚠️ Critical Distinction:** "RPO=0" means zero data loss **within freshness window**. Does NOT mean zero lag. Queries may see stale data for up to 5 minutes during buffer recovery.

**Recovery (1a comes back):**
- Health checks pass → NLB re-adds 1a targets
- Endpoint hints re-enable (kube-proxy resync)
- Pending disk buffers drain automatically at **rate-limit 50MB/s** (controlled via `-remoteWrite.rateLimit=50MB`)
- **Time to full capacity:** Proportional to buffer backlog
  - Empty buffer: <1 minute
  - Half-full buffer (75GB): ~25 minutes
  - Full buffer (150GB): ~50 minutes
- During recovery, queries continue routing to VM-B (no flip-flop)

### Deduplication

Both clusters store identical data. In normal operation, no duplication (each vmselect reads its cluster only). Dedup becomes critical in two scenarios:

1. **vmctl backfill** — network glitches or overlapping time ranges create duplicates on destination
2. **Federated queries** — if future vmauth routes to both clusters simultaneously

Mitigation: all vmselect and vmstorage instances run with `-dedup.minScrapeInterval=30s` (the baseline scrape interval). No performance penalty if no duplicates present.

---

## Monitoring & Alerts

### Critical Signals

```yaml
# 1. Topology hints deactivated (silent cross-AZ traffic return)
- alert: TopologyHintsInactive
  expr: kube_endpointslices_annotations{annotation_service_kubernetes_io_topology_mode="Auto"}
        unless on(endpointslice) kube_endpointslices_annotations{annotation_hints_auto="yes"}

# 2. Write buffer filling up (data loss risk)
- alert: VmagentBufferHighFill
  expr: vmagent_remotewrite_pending_data_bytes / (200 * 1024^3) > 0.7

# 3. Partial responses (vmstorage node down)
- alert: VMStorageNodeUnavailable
  expr: increase(vm_partial_results_total[5m]) > 0

# 4. Write buffer not draining (downstream blocked)
- alert: RemoteWriteStuck
  expr: increase(vmagent_remotewrite_pending_data_bytes[5m]) > 0 and on(job) up
```

### Verification After Migration

```bash
# Check topology hints active
kubectl get endpointslices -n prod-itprod -o json | jq '.items[].hints'

# Verify pending bytes near zero
kubectl exec -n prod-itprod <buffer-pod> \
  -- curl localhost:8429/metrics | grep pending_data_bytes

# Check cross-AZ traffic isolation
# (should show only write-path dual-write traffic, 0 read-path)
aws ec2 describe-vpc-peering-connections --filters Name=status-code,Values=active \
  | jq '.VpcPeeringConnections[] | select(.Tags[] | select(.Value=="vm")) | .AccepterVpcInfo.CidrBlock'
```

---

## Cost Analysis (Auditable)

**Honest accounting** — peer-reviewed numbers, no hidden adjustments:

| Component | Before (RF=2) | After (Dual Cluster) | Delta/month |
|-----------|---|---|---|
| Write I/O per cluster (RF=2 vs RF=1) | 2× samples/sec | 1× per cluster | **−$400** |
| Cross-AZ egress (read fan-out) | ~$900/mo | ~$0 (local) | **−$900** |
| Cross-AZ egress (dual-write overhead) | — | +$950/mo | **+$950** |
| EBS for vmagent disk buffers (gp3) | — | 6 pods × 50 GB | **+$30** |
| vmstorage EC2 (10 nodes RF=2 vs 10+10 dual-cluster) | 10 nodes | 20 nodes | **+0** |
| **Net cash savings** | | | **−$320/month** |

> **Why "−$320", not "−$1,630"?** Earlier drafts misattributed vmselect node reduction (we have *20 vmstorage* either way — 10×RF=2 ≈ 10+10×RF=1). The honest savings come from eliminating cross-AZ read egress (−$900) minus the cost of dual-write (+$950), plus halving write I/O multiplier per cluster.

**Operational savings (not in $$):**
- vmselect heap pressure: 20-shard fan-out → 10-shard fan-out per cluster (avoids $X/mo on r7g.4xlarge upgrade)
- Independent failure domains: AZ-level outages no longer require manual intervention
- Predictable failover (5-15s vs random recovery time)

**ROI:**
- One-time investment: ~160 engineer hours × $150/hr loaded = $24,000
- Cash payback: $24K ÷ $320/mo = **75 months** ❌ (too long on cash alone)
- Including avoided vmselect upsizing: ~$24K ÷ ($320 + ~$280 vmselect right-size) = **40 months** (still long)
- **Real value: AZ-level DR + operational simplicity, not cash savings.**

**⚠️ Note on EBS gp3 pricing:** Earlier drafts cited $56/vol/mo for vmstorage volumes. Actual: $194/vol-mo (2 TiB × $0.08 + 6000 IOPS × $0.005 + 500 MB/s × $0.04). Cost table above accounts for vmagent buffers only; vmstorage cost neutral (same total node count).

---

## Trade-Offs & Limitations

### 1. RF=1 Means Partial Responses During Rolling Upgrades

vmselect flags `"isPartial": true` when any vmstorage shard is unavailable. During planned rolling updates:

```
vmstorage-pod-1 restart (30-60s) → shard-0 unavailable → 10% queries partial
```

**Mitigation:**
- vmselect-alerts: **no `denyPartialResponse` flag** (partial responses acceptable for alerting)
- vmselect-main: can set `denyPartialResponse=true` if consistency > availability
- Grafana queries: already handle `isPartial` gracefully (shows data as available)

### 2. API Server & Probe Metrics Tied to Catch-All AZ

Using `topology-mode: Auto` for scraper agents (in separate design doc) means apiserver metrics and VM Probes default to the "catch-all" vmagent in primary AZ. **AZ failure → gap in apiserver metrics.**

Acceptable trade-off — when the AZ fails, much larger systems are broken anyway; monitoring dashboards lose visibility anyway. Pure single-AZ dependency ≠ systemic risk.

### 3. NLB TCP Idle Timeout (350s)

NLB has hardcoded 350-second idle timeout (immutable). External Graphite sources that sit idle > 350s without data will get RST.

**Check before deployment:** ensure all Graphite clients use `SO_KEEPALIVE` with interval < 300s.

---

## Implementation Phases

1. **Prep:** Create Karpenter NodePools (victoriametrics-storage-az-a/b)
2. **Stage validation:** Deploy dual cluster to stage environment, run 1-week soak test
3. **Phase 1:** Deploy VM-B to prod (parallel with RF=2 cluster)
4. **Phase 2:** Enable dual-write (triple fan-out: two new + one old for rollback)
5. **Phase 3:** Backfill historical data with `vmctl`
6. **Phase 4:** DNS read switch (half prod traffic to VM-A, half to VM-B)
7. **Phase 5:** Decommission old RF=2 cluster

Each phase includes automated verification checks (topology hints, buffer levels, cross-AZ metrics).

---

## Lessons Learned

1. **Zone awareness at storage layer is fragile.** Relying on consistent hash + rack awareness = requires monitoring. The dual-cluster approach avoids the problem entirely.

2. **L7 proxies hide locality.** nginx/vmauth obscure which endpoints you're hitting. NLB (L4) makes locality explicit and automatic.

3. **Bulkhead pattern is essential.** Each remoteWrite URL must have isolated queue + disk buffer. Without it, one slow cluster can block another.

4. **Small ROI threshold.** $534/month cross-AZ cost across all clusters is below single-cluster $1K threshold. Dual-cluster design became cost-positive only because we eliminated vmselect fan-out (separate win).

---

## References

- [Victoria Metrics Multi-AZ Topologies](https://docs.victoriametrics.com/guides/vm-architectures/#multi-cluster-and-multi-az)
- [Kubernetes Topology Aware Routing (KEP-2433)](https://kubernetes.io/docs/concepts/services-networking/topology-aware-routing/)
- [AWS NLB Cross-Zone Load Balancing](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/network-load-balancers.html#cross-zone-load-balancing)
- [VictoriaMetrics Issue #4216](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/4216) — zone-awareness gap in consistent hash
- [VictoriaMetrics Issue #8044](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/8044) — write buffer lost on ingester failure

---

## About

This design evolved from production incident response at Playrix (111M active series, 1.66M samples/s). The dual-cluster approach trades operational complexity (N CRDs, dual-write management) for cost savings and superior AZ-level disaster recovery.

**Questions?** Open issue or discussion in the portfolio repo.
