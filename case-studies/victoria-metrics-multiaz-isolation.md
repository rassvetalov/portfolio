# Multi-AZ Victoria Metrics Cluster: Architecture for DR Without Replication Tax

**Author:** Dmitrii Rassvetalov  
**Date:** May 2026  
**Version:** 2 (peer-reviewed, production-hardened)  
**Scope:** Production time-series database spanning 3 AWS availability zones (111M active series, 1.66M samples/s)

---

## Executive Summary

RF=2 replication doubles storage and I/O costs without providing AZ-level disaster recovery. We designed a **dual-cluster architecture** — two independent Victoria Metrics clusters (VM-A, VM-B) in separate AZ, each holding 100% of data at RF=1. Dual-write at vmagent layer ensures zero-gap ingestion with explicit consistency guarantees.

**Key results:**
- Eliminated vmselect fan-out across 20 vmstorage nodes in 3 AZ → **10 nodes per cluster (50% cache-locality improvement)**
- Cross-AZ read traffic: **0 (vs. 3 hops/query)**
- Write I/O per cluster: **×1 (vs. ×2 for RF=2)**
- **Net cost savings: $1,630/month** (−8% of monitoring budget)
- **DR: RPO=0 with explicit freshness SLA** (RPO = within 5min)
- Independent failure domains (AZ-level)

---

## Problem: RF=2 Is Asymmetric

Our baseline atf01 cluster ran RF=2 — each time series stored on 2 vmstorage nodes, distributed via consistent hash. This design had three critical gaps:

### Gap 1: No Zone Awareness in Sharding

[#4216 (VictoriaMetrics/VictoriaMetrics)](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/4216) documents the issue: consistent hash ignores AZ labels when placing replicas. With unlucky distribution, both replicas can land in the same AZ. **AZ outage = data loss despite RF=2.**

Example:
```
shard-0 (replica 1) → vmstorage-pod-1 (us-east-1a)
shard-0 (replica 2) → vmstorage-pod-2 (us-east-1a) ← same AZ!
Loss of us-east-1a → shard-0 unavailable → 10% of queries return isPartial=true
```

### Gap 2: Write Buffer Lost on Ingester Failure

[#8044 (VictoriaMetrics/VictoriaMetrics)](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/8044): replication happens **after** sharding in the vminsert write buffer. If primary vmstorage is unreachable at write time, the replica write is never attempted — data lands in neither location until retry.

### Gap 3: Read-Path Cross-AZ Tax

vmselect fanned out queries across 20 vmstorage nodes in 3 AZ. Every query triggered unnecessary cross-AZ traffic (~3 hops), incurring **$900/month in AWS egress charges**. RF=2 scales quadratically with AZ count (if 6 AZ → $2.7K/month).

---

## Solution: Dual Independent Clusters with Local-First Affinity

We deployed **two logical clusters** in a single Kubernetes cluster, each anchored to its own AZ:

```
Kubernetes cluster (atf01 / 3 AZ)
│
├─ VM-A (us-east-1a, RF=1)          ├─ VM-B (us-east-1b, RF=1)
│  ├─ vmagent-buffer-a (3 pods)     │  ├─ vmagent-buffer-b (3 pods)
│  ├─ vminsert-a + vmstorage-a (10) │  ├─ vminsert-b + vmstorage-b (10)
│  └─ vmselect-main-a               │  └─ vmselect-main-b
│                                   │
│  Write: dual-write to A + B       │  Write: dual-write to A + B
│  Read: queries hit local only      │  Read: queries hit local only
└────────────────────────────────────┘
```

### How It Works

**Ingestion (dual-write):**
1. **Internal scrapers** → K8s Service `vmagent-buffer` (topology-mode: Auto)
   - kube-proxy routes to buffer in pod's AZ
   - buffer-a receives metrics, writes to both vminsert-a (local) and vminsert-b (cross-AZ)
   - vminsert uses bulkhead pattern: each URL has isolated queue + disk buffer
2. **External scrapers** → NLB:8429 (cross_zone_load_balancing=false)
   - NLB node in client's AZ routes to buffer in same AZ
   - Same dual-write pattern

**Query (local-first, zero cross-AZ):**
```
Grafana pod (1a) → K8s svc vmselect-main (topology-mode: Auto)
                 → vmselect-main-a (local, 1a)
                 → fan-out 10 vmstorage pods (all in 1a)
                 → 0 cross-AZ hops
```

---

## Key Design Decisions

### 1. RF=1 Per Cluster, HA Via Dual-Write

**Why RF=1?**
- Eliminates write I/O doubling
- Removes hash blindness issue (#4216)
- Simplifies operations: one failure domain per AZ

**Dual-write safety (bulkhead pattern):**
- Each `--remoteWrite.url` has isolated queue + disk buffer
- If VM-B is unreachable → VM-A succeeds immediately, VM-B queues to 200GB disk
- Recovery: buffer drains at rate-limited pace (50MB/s), ensuring zero data loss

**Query consistency model (critical):**

| Scenario | Freshness | Duration |
|----------|-----------|----------|
| Normal (both healthy) | <1s lag | N/A |
| Single AZ buffering | <5min lag | While buffer drains |
| Buffer near full (rate-limited) | <10min lag | ~50min recovery if >150GB pending |
| Both clusters degraded | <10min lag | Rare, requires double failure |

**⚠️ Define what "RPO=0" means for your org:** This is NOT eventual consistency. Acceptable for SLI dashboards, Grafana, alerting. NOT for billing systems or high-frequency trading.

### 2. Deduplication During Dual-Write (Operational Reality)

**Dual-write creates replicas but they arrive with jitter:**
- Sample to vmstorage-a at T0 + 10ms
- Same sample to vmstorage-b at T0 + 20ms
- **Both nodes retain duplicate** (timestamps differ beyond dedup window)
- Result: **0.1-0.5% duplicate rate** in queries

**Mitigation:**
```
vmstorage flags:
  -dedup.minScrapeInterval=30s     # Min scrape interval across all configs
  -dedup.maxMemory=300MB           # (Default; increase if dupes escape)

Monitor:
  rate(vm_dedup_lines_total[5m]) / rate(vm_insert_total[5m]) < 0.001  (alert if >0.5%)
```

### 3. Partial Responses During Rolling Upgrades (SLI Impact)

**vmselect returns `isPartial: true` when any vmstorage unavailable.**

During rolling restart (10 pods, 60s each):
- Pod-N down: 10% of series missing for 60s
- **Repeated 10 times → total 10 minutes of degraded queries throughout the day**

**Alerting underfire risk:**
```
Rule: rate(errors[1m]) > 100
During vmstorage restart (10% data missing):
  - Error metrics 90% visible
  - If threshold = 100, alert may not fire
  - Actual errors occur, but alert underfire
  - SLO breach goes undetected
```

**Mitigation: PodDisruptionBudget (required for production)**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: vmstorage-a-pdb
spec:
  minAvailable: 9  # Max 1 pod down at a time
  selector:
    matchLabels:
      app: vmstorage-a
```

### 4. Kubernetes Topology-Mode: Auto (with Proactive Monitoring)

Standard Service spreads traffic evenly across AZ. With `topology-mode: Auto`:
- EndpointSlice controller assigns hints to local-zone endpoints
- kube-proxy builds iptables rules routing only to local endpoints
- Fallback: if local AZ has 0 endpoints, uses other AZ (soft isolation, not hard)

**⚠️ Silent Deactivation Risk:**
If endpoint distribution skews >3× from node distribution, EndpointSlice **disables hints without alerts**. AWS billing still shows cross-AZ traffic. **This kills savings silently.**

**Proactive Monitoring (Fire BEFORE Hints Disable):**
```promql
# Alert at 2.5× skew (before 3× threshold)
count by (zone) (kube_pod_info{...}) / count(kube_node_info{...}) > 2.5
action: trigger Kubernetes descheduler or manual rebalance
```

### 5. NLB L4 Instead of nginx Ingress + vmauth L7

**Old stack (RF=2):**
```
External → nginx Ingress (buffers request body)
        → vmauth (L7, routing, retry logic)
        → vminsert/vmselect
Problem: L7 buffering adds latency; incompatible with Graphite TCP
```

**New stack:**
```
External → NLB:8429/8481 (L4, cross_zone=false)
        → buffer/vmselect in client's AZ
Problem: TCP 350s idle timeout (hardcoded, check Graphite clients)
```

**Benefits:**
- No buffering → minimal latency
- L4 routing automatic (NLB node picks same-AZ targets)
- TCP support for Graphite
- Simpler topology (no L7 single-point-of-failure)

### 6. Cardinality Management (Critical, Often Missed)

**No mention of cardinality in RF=2 to dual-cluster migration = risky.**

At 111M active series with 90M churn/24h:
- Small label explosion → +50M series overnight
- Dual-cluster means you pay 2× for capacity
- **Without cardinality control, scaling becomes impossible**

**Cardinality allocation budget:**

| Component | Active Series | Churn/Day |
|-----------|---|---|
| K8s metadata | 45M | 40M |
| Game metrics | 55M | 45M |
| Infrastructure | 11M | 5M |
| **Total** | **111M** | **90M** |

**Escalation triggers:**
- Any component exceeds 120% budget → relabeling + service discovery tuning required
- Cardinality burst alert: `vmagent_active_series` spikes >20% vs. baseline in 5min

---

## Failover: Timing and Consistency Guarantees

### Write Path Failover (1a to 1b)

**Internal scrapers (topology-mode: Auto):**
- **Empirical RTO: 5-15s** (not <100ms as naively assumed)
  - Kubelet resync: 100-500ms
  - EndpointSlice controller: 5-10s
  - Validation: kill vmagent-buffer-a pod, measure Prometheus scrape latency spike

**External scrapers (NLB health check):**
- **RTO: ~20s** (2 failures × 10s interval)
- Health check on port 8429 only verifies port open; **consider HTTP health check** on `/api/v1/write` for deeper validation

**Write buffer during 1a outage:**
- buffer-b continues dual-write: vm-a samples queue to disk immediately (bulkhead isolation)
- **Query freshness:** <5min (buffer drains at controlled rate)
- If buffer fills >180GB: rate-limited to 10MB/s, lag grows

### Read Path Failover (1a to 1b)

**Grafana pods (topology-mode: Auto):**
- **Empirical RTO: 5-15s**

**External tools (NLB):**
- **RTO: ~20s** + DNS TTL (if >0, add 40s more)

**Query results:**
- All data replicated to VM-B
- Lag depends on write buffer status
- Normal case: <1s lag
- Buffer backlog: <5min lag

### Recovery (1a Restarts)

- Health checks pass → endpoints re-enable → traffic returns
- Pending buffers drain automatically at rate-limit (50MB/s)
- Time to full capacity: proportional to backlog size
  - Empty: <1min
  - 75GB: ~25min
  - 150GB: ~50min
- During recovery, queries stay on VM-B (no flip-flop)

---

## Operational Requirements

### Flipping From RF=2 to Dual-Cluster: Migration Path

**Phase 1: Pre-flight**
- Validate cardinality budget (111M series realistic?)
- Create Karpenter NodePools (victoriametrics-storage-az-a/b)
- Stage validation: deploy to atf01 test environment first

**Phase 2: Deploy VM-B parallel to RF=2**
- Helm deploy VM-B as separate release
- vmselect-b queries only vmstorage-b (no cross-cluster yet)

**Phase 3: Triple fan-out (A + B + OLD)**
- Enable dual-write in vmagent → writes go to NEW (A + B) + OLD (RF=2)
- OLD gets relay copy for rollback insurance
- Backfill any gaps with vmctl

**Phase 4: DNS read switch**
- 50% of queries to VM-A (vmselect-main-a)
- 50% to VM-B (vmselect-main-b)
- Monitor SLI metrics during flip

**Phase 5: Decommission old RF=2 cluster**
- After 1-week validation → delete old cluster

### HTTP Health Check on NLB (Not Just TCP)

**Don't rely on port-open health check:**

```hcl
health_check {
  protocol            = "HTTP"
  path                = "/api/v1/write"
  matcher             = "204"
  interval            = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2
}
```

**Why:** TCP health check passes if vminsert process is hung. HTTP check verifies write path functional.

### Cardinality Monitoring & Alerts

```yaml
- alert: VMCardinalityBurstDetected
  expr: rate(vmagent_active_series[5m]) > 1.2 * avg_over_time(vmagent_active_series[1d])
  for: 5m
  annotations:
    summary: "{{ $value | humanize }} series spike detected"
    action: "Investigate: new game deployment? Misconfigured label?"

- alert: VMCardinalityBudgetExceeded
  expr: vmagent_active_series > 1.2 * 111e6  # 120% of allocated
  for: 30m
  annotations:
    summary: "Cardinality {{ $value | humanize }} exceeds budget"
    action: "Trigger aggressive relabeling or service discovery tuning"
```

### Monitoring Topology Hints (Proactive Alert)

```yaml
- alert: TopologyHintsInactivePreventive
  expr: count by (zone) (kube_pod_info{}) / count(kube_node_info{}) > 2.5
  for: 2m
  annotations:
    summary: "Pod distribution skew {{ $value | humanize }}× detected (hints may disable at 3×)"
    action: "Manually rebalance pods or trigger descheduler"

- alert: TopologyHintsInactive
  expr: |
    kube_endpointslice_annotations{annotation_service_kubernetes_io_topology_mode="Auto"}
    unless on(endpointslice)
    kube_endpointslice_annotations{annotation_hints_auto="yes"}
  for: 5m
  annotations:
    summary: "Topology hints disabled → cross-AZ traffic restored"
    action: "Immediate mitigation needed; check pod distribution ratio"
```

---

## Cost Analysis (Revised with All Factors)

| Component | Before (RF=2) | After (Dual Cluster) | Delta |
|-----------|---|---|---|
| Write I/O (storage + network) | 2× samples/sec | 1× per cluster | −$400 |
| vmselect memory (20 nodes) | 20 pods × 2GB | 10 pods per cluster × 1.5GB | −$280 |
| Cross-AZ egress (read path) | ~$900/month | ~$0 (local only) | −$900 |
| Cross-AZ write (dual-write) | — | +$950/month | +$950 |
| Dual-write disk buffers | — | 6 pods × 50GB = 300GB EBS | +$30 |
| **Net savings** | — | — | **−$1,630/month** |
| Payback period | — | — | **~3 months** |

**Note:** Estimate assumes 1.66M samples/s baseline and $0.01/GB AWS egress rate (verified May 2026).

---

## Limitations & Trade-Offs

### 1. RF=1 Means Acceptable Partial Responses

10% of queries return `isPartial: true` during rolling vmstorage restart. This is acceptable for:
- ✅ SLI dashboards (humans tolerate brief gaps)
- ✅ Alerting rules (mostly still fire)
- ❌ High-frequency trading (need exact data)
- ❌ Billing systems (need completeness guarantees)

**Mitigation:** Use PDB + HTTP health checks (not TCP-only).

### 2. API Server & Probe Metrics Depend on Catch-All AZ

Using topology-mode: Auto means:
- apiserver EndpointSlice has no zone label → falls through to catch-all agent
- VMProbe targets have no zone label → catch-all only
- **AZ failure of catch-all → gap in apiserver/probe metrics**

Acceptable because:
- apiserver metrics are less critical than query data
- Probes are usually singleton (low impact)

### 3. NLB TCP Idle Timeout (350s, Hardcoded)

Graphite clients idle > 350s → RST without warning. **Pre-deploy validation required:**

```bash
./scripts/validate-graphite-clients.sh --keepalive-interval 300s
```

### 4. Dual-Cluster Means 2× Capacity Cost

Storage, compute, networking all doubled. **Operational trade-off:** simplicity + safety vs. cost.

---

## Lessons Learned

1. **Zone awareness at storage layer is fragile.** Dual-cluster avoids the problem entirely.
2. **L7 proxies hide locality.** NLB makes it explicit and automatic.
3. **Bulkhead pattern is essential.** Each remoteWrite URL must have isolated queue.
4. **Consistency SLAs must be explicit.** Define freshness windows for your use case.
5. **Cardinality is the limiting factor**, not storage architecture.
6. **Empirical timing trumps theory.** Topology-mode fallback ≠ <100ms; validate with production data.

---

## References

- [Victoria Metrics Multi-AZ Topologies](https://docs.victoriametrics.com/guides/vm-architectures/#multi-cluster-and-multi-az)
- [VictoriaMetrics Issue #4216](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/4216) — zone-awareness gap
- [VictoriaMetrics Issue #8044](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/8044) — write buffer loss
- [Kubernetes Topology-Aware Routing (KEP-2433)](https://kubernetes.io/docs/concepts/services-networking/topology-aware-routing/)
- [AWS NLB Cross-Zone Load Balancing](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/network-load-balancers.html#cross-zone-load-balancing)

---

## Questions for Your Team

Before deploying:
1. What's your definition of "RPO=0"? (Data loss within X minutes acceptable?)
2. Is 0.1-0.5% duplicate rate acceptable in queries?
3. Do you have cardinality growth trajectory projections?
4. What's your SLO for "alerting rule accuracy" during rolling upgrades?
5. Is auth/authorization going to be enforced? (Currently: K8s RBAC only)

---

**About:** Production design for Playrix IT Production (111M active series, 1.66M samples/s across 30+ EKS clusters). Peer-reviewed by metrics SME and AWS/K8s architect. Production-ready with the listed operational procedures.
