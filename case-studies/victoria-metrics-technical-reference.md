# Technical Reference: Victoria Metrics Multi-AZ Architecture

**For:** Site Reliability Engineers, DevOps architects, platform teams  
**Updated:** May 2026

---

## Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                   Kubernetes Cluster: atf01 (3 AZ)                      │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                     VM-A (us-east-1a)                           │   │
│  ├──────────────────────────────────────────────────────────────────┤   │
│  │                                                                  │   │
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌─────────────┐   │   │
│  │  │ vmagent-buffer-a │  │   vminsert-a    │  │ vmstorage-a │   │   │
│  │  │ (3 pods × 50GB)  │→→│                 │→→│ (10 nodes,  │   │   │
│  │  │ dual-write a,b   │  │                 │  │ 2TB each)   │   │   │
│  │  └──────────────────┘  └──────────────────┘  └─────────────┘   │   │
│  │       ↑                                              ↓           │   │
│  │    write-nlb:8429                           fan-out: 10 nods    │   │
│  │                                                                  │   │
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌─────────────┐   │   │
│  │  │ vmselect-main-a  │  │ vmselect-alerts  │  │ vmselect-   │   │   │
│  │  │ (5 pods)         │  │ (2 pods)         │  │ export (2)  │   │   │
│  │  │ K8s svc          │  │ K8s svc          │  │ NLB:8481    │   │   │
│  │  │ topology:Auto    │  │ topology:Auto    │  │             │   │   │
│  │  └──────────────────┘  └──────────────────┘  └─────────────┘   │   │
│  │       ↓                      ↓                    ↓              │   │
│  │    Grafana (local)    vmalert (local)    BI/ETL (ext)          │   │
│  │                                                                  │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                     VM-B (us-east-1b)                           │   │
│  ├──────────────────────────────────────────────────────────────────┤   │
│  │ [Mirror of VM-A, nodeAffinity: 1b]                              │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                     VM-C (us-east-1c)                           │   │
│  ├──────────────────────────────────────────────────────────────────┤   │
│  │ [Optional: alternate AZ, same topology]                         │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
├──────────────────────────────────────────────────────────────────────────┤
│                           External Clients                               │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  VPC Peering   →  NLB:8429 (cross_zone=false)  →  vmagent-buffer-[a|b] │
│  External HTTP →  NLB:8481 (cross_zone=false)  →  vmselect-main-[a|b]  │
│  External HTTP →  NLB:8482 (cross_zone=false)  →  vmselect-alerts-[a|b]│
│  BI/ETL Export →  NLB:8481 (cross_zone=false)  →  vmselect-export-[a|b]│
│  Graphite TCP  →  NLB:2003 (cross_zone=false)  →  vmagent-buffer-[a|b] │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Data Flow

### Write Path (Dual-Write)

```
Metrics Source
    ├─ Internal scraper (pod in 1a)
    │  └─ K8s Service vmselect-main (topology-mode: Auto)
    │     └─ kube-proxy routes to buffer-a (local AZ)
    │        └─ vmagent-buffer-a receives metrics
    │           ├─ Write to vminsert-a (local)
    │           │  └─ vminsert-a → vmstorage-a (10 nods RF=1)
    │           └─ Write to vminsert-b (cross-AZ via bulkhead pattern)
    │              └─ vminsert-b → vmstorage-b (10 nodes RF=1)
    │
    ├─ External scraper (VPC peering from us-east-1a region)
    │  └─ write-nlb:8429
    │     └─ NLB node in 1a
    │        └─ Routes to buffer-a pod
    │           └─ [same dual-write as above]
    │
    └─ Graphite producer (port 2003)
       └─ write-nlb:2003
          └─ [same routing, Graphite TCP support]

Buffer Storage:
  per-pod: 200GB EBS gp3 at 6000 IOPS (needed for compaction burst)
  per-AZ: 3 pods × 200GB = 600GB total
  retention on disk: ~5 days failover window
```

### Read Path (Zero Cross-AZ)

```
Query Source
  ├─ Grafana pod (in 1a, via K8s Service)
  │  └─ vmselect-main K8s svc (topology-mode: Auto)
  │     └─ kube-proxy iptables → endpoints in 1a only
  │        └─ vmselect-main-a pod
  │           └─ fan-out to 10 vmstorage-a pods (local)
  │              └─ **0 cross-AZ hops**
  │                 Failover: vmselect-main-a unavailable
  │                 → kube-proxy fallback to vmselect-main-b
  │                    → vmselect-main-b queries vmstorage-b
  │
  ├─ External tool (VPN)
  │  └─ vm-read-nlb:8481
  │     └─ NLB node in same AZ as client
  │        └─ Routes to vmselect-main-[a|b] in that AZ
  │           └─ **0 cross-AZ** (NLB node affinity)
  │
  └─ vmalert (in 1a)
     └─ vmselect-alerts K8s svc
        └─ [same topology routing as Grafana]
```

---

## Karpenter NodePool Configuration

```hcl
# victoriametrics-storage-az-a/terragrunt.hcl
inputs = {
  name = "victoriametrics-storage-az-a"
  
  # Hard AZ constraint
  topology_zone = "us-east-1a"
  
  # Instance sizing for vmstorage (8 vCPU, 64GB min)
  instance_types = [
    "r7g.2xlarge",   # 8 vCPU, 64 GB
    "r7g.4xlarge",   # 16 vCPU, 128 GB (fallback)
    "r8g.2xlarge",
    "r8g.4xlarge",
  ]
  
  # AMI & tagging
  ami_family           = "AL2023"
  ami_name             = "amazon-eks-node-al2023-arm64-standard-1.34-v20260209"
  tag_plr_cost_allocation = "victoriametrics"
  
  # Disruption: CRITICAL — WhenEmpty only
  disruption = {
    consolidationPolicy = "WhenEmpty"  # NOT WhenEmptyOrUnderutilized
    consolidateAfter    = "30s"
    budgets = [{
      nodes   = "10%"
      reasons = ["Empty"]
    }]
  }
}

terraform {
  source = "git::github.com/Playrix/itprod-terraform-aws-eks//karpenter-nodepool?ref=v10.1.0"
}
```

**Why `WhenEmpty` not `WhenEmptyOrUnderutilized`?**
- Underutilized mode evicts pods when node < 50% CPU/memory
- At RF=1, losing one vmstorage = ~10% of queries return `isPartial: true` for 60s
- Not acceptable for storage tier

---

## Pod Disruption Budget (CRITICAL — BOTH CLUSTERS)

**RF=1 requires PDB to prevent silent alerting underfire during rolling upgrades.**
**Symmetry rule: cluster-B needs the same PDBs as cluster-A.**

```yaml
# === CLUSTER A (us-east-1a) ===
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: vmstorage-a-pdb
  namespace: prod-itprod
spec:
  minAvailable: 9  # Max 1 pod down at a time; prevents 10% partial queries
  selector:
    matchLabels:
      app: vmstorage-a
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: vmselect-main-a-pdb
  namespace: prod-itprod
spec:
  minAvailable: 4  # 5 pods; allow 1 disruption
  selector:
    matchLabels:
      app: vmselect-main-a
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: vmagent-buffer-a-pdb
  namespace: prod-itprod
spec:
  minAvailable: 2  # 3 buffer pods; allow 1 disruption
  selector:
    matchLabels:
      app: vmagent-buffer-a
---
# === CLUSTER B (us-east-1b) — MIRROR ===
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: vmstorage-b-pdb
  namespace: prod-itprod
spec:
  minAvailable: 9  # Same protection as cluster-A
  selector:
    matchLabels:
      app: vmstorage-b
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: vmselect-main-b-pdb
  namespace: prod-itprod
spec:
  minAvailable: 4
  selector:
    matchLabels:
      app: vmselect-main-b
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: vmagent-buffer-b-pdb
  namespace: prod-itprod
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: vmagent-buffer-b
---
# === SCRAPER VMAgents (if zone-aware deployed) ===
# Catch-all needs less strict PDB since it has more shards
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: vmagent-zone-1a-catchall-pdb
spec:
  minAvailable: 4  # 5 shards; allow 1 shard disruption
  selector:
    matchLabels:
      app: vmagent-zone-1a-catchall
```

**Why minAvailable vs. maxUnavailable:**
- `minAvailable: 9` = Kubernetes guarantees ≥9 pods running
- During rolling upgrade: max 1 pod can be evicted simultaneously
- Prevents 2+ vmstorage pods down at same time (which = 20% partial queries)

---

## Pod Affinity Rules

### vmstorage Pods (Strict Isolation + PDB)

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: topology.kubernetes.io/zone
              operator: In
              values: ["us-east-1a"]
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: vmstorage-a
        topologyKey: kubernetes.io/hostname  # One pod per node
tolerations:
  - key: vm-az
    value: a
    effect: NoSchedule
```

**Why podAntiAffinity required?**
- RF=1 means two vmstorage-a on same node → node failure loses 2/10 shards (20% partial responses)
- Preferred ≠ guaranteed → scheduler can ignore under pressure
- Required + PDB = production-safe guarantee

### vmagent-buffer, vminsert Pods (Preferred)

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:  # AZ required
      nodeSelectorTerms:
        - matchExpressions:
            - key: topology.kubernetes.io/zone
              operator: In
              values: ["us-east-1a"]
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:  # Preferred, not required
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: vmagent-buffer-a
          topologyKey: kubernetes.io/hostname
```

### vmselect Pods (Preferred)

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:  # AZ required
      nodeSelectorTerms:
        - matchExpressions:
            - key: topology.kubernetes.io/zone
              operator: In
              values: ["us-east-1a"]
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:  # Preferred, not required
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: vmselect-main-a
          topologyKey: kubernetes.io/hostname
```

---

## Kubernetes Service: Topology Mode Auto

```yaml
---
# Read path
apiVersion: v1
kind: Service
metadata:
  name: vmselect-main
  namespace: prod-itprod
  annotations:
    service.kubernetes.io/topology-mode: Auto
spec:
  type: ClusterIP
  selector:
    app: vmselect-main      # Matches BOTH vmselect-main-a AND vmselect-main-b
  ports:
    - port: 8481
      targetPort: 8481
      name: http

---
# Write path
apiVersion: v1
kind: Service
metadata:
  name: vmagent-buffer
  namespace: prod-itprod
  annotations:
    service.kubernetes.io/topology-mode: Auto
spec:
  type: ClusterIP
  selector:
    app: vmagent-buffer     # Matches BOTH vmagent-buffer-a AND vmagent-buffer-b
  ports:
    - port: 8429
      targetPort: 8429
      name: http
```

**How `topology-mode: Auto` works:**
1. EndpointSlice controller reads `topology.kubernetes.io/zone` labels on each pod's node
2. Sets `hints.forZones` on endpoints in the same AZ
3. kube-proxy on each node builds iptables rules routing **only** to local-zone endpoints
4. Fallback: if local AZ has 0 healthy endpoints, kube-proxy uses other AZ

**⚠️ Silent deactivation risk:**
If endpoints skew >3× from nodes, EndpointSlice disables hints. **No alerts.** AWS billing still shows cross-AZ traffic.

**Monitor with:**
```promql
kube_endpointslice_annotations{
  annotation_service_kubernetes_io_topology_mode="Auto"
} unless on(endpointslice)
kube_endpointslice_annotations{
  annotation_hints_auto="yes"
}
```

---

## NLB Configuration

```hcl
# Terraform
resource "aws_lb" "write_nlb" {
  name               = "atf01-vm-write-nlb"
  load_balancer_type = "network"
  internal           = false
  
  enable_cross_zone_load_balancing = false  # CRITICAL: stay in zone
}

resource "aws_lb_target_group" "write_targets" {
  name        = "atf01-vm-write-tg"
  port        = 8429
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"   # Required for TargetGroupBinding (pod IPs)
  
  # CRITICAL: HTTP health check, not TCP
  # TCP-only check passes if vminsert process is hung but not accepting writes
  health_check {
    protocol            = "HTTP"
    path                = "/api/v1/write"
    matcher             = "204"
    port                = "8429"
    interval            = 5    # Fast failover
    healthy_threshold   = 2
    unhealthy_threshold = 2    # ~10s to failover
  }
  
  # NLB connection idle timeout — configurable since Sept 2024
  # (was previously hardcoded to 350s, this constraint no longer applies for TCP listeners)
  connection_termination = false
}
```

```yaml
# Use TargetGroupBinding (preferred over aws_lb_target_group_attachment for pod IPs)
# Per Playrix workspace standards — see itprod-docker .cursorrules
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: vmagent-buffer-tgb
  namespace: prod-itprod
spec:
  serviceRef:
    name: vmagent-buffer  # ClusterIP service matching both buffer-a + buffer-b
    port: 8429
  targetGroupARN: arn:aws:elasticloadbalancing:...:targetgroup/atf01-vm-write-tg/...
  targetType: ip
```

**Why `cross_zone_load_balancing = false`?**
- NLB has 3 nodes (one per AZ)
- NLB node in 1a only forwards to targets in 1a
- Client from 1a region → NLB node in 1a → buffer pod in 1a
- Automatic locality, no cross-AZ on write path buffer layer

**Why HTTP health check over TCP?**
- TCP check only verifies port is open
- HTTP check verifies `/api/v1/write` endpoint responds with 204
- Catches hung vminsert processes that TCP check would miss
- Status code 204 (No Content) is correct for empty write request

**NLB TCP idle timeout (UPDATED Sept 2024):**
- Previously: hardcoded 350s
- Now: **configurable 60-6000s** for TCP listeners (TLS still 350s fixed)
- Set explicitly via `tcp_idle_timeout_seconds` attribute
- Still recommended: Graphite clients use `SO_KEEPALIVE` < 300s for safety

```hcl
resource "aws_lb_listener" "write" {
  load_balancer_arn = aws_lb.write_nlb.arn
  port              = 8429
  protocol          = "TCP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.write_targets.arn
  }
  
  # Configurable since Sept 2024 — extend beyond 350s for batch Graphite clients
  tcp_idle_timeout_seconds = 600
}
```

---

## Failover Sequence (Empirical Timing)

### Scenario: us-east-1a AZ Outage (Duration: T0 to T0+5min)

> **Important:** Timings below are *empirical* (measured on production atf01),
> not theoretical. Validate on your cluster: kill `vmagent-buffer-a-0` pod and
> measure scrape latency spike.

```
T0:00     │ Packet loss begins; kubelet probes fail
T0:05-15  │ ┌─ Write path (empirical RTO 5-15s, NOT <100ms)
          │ │  - Kubelet probe: 100-500ms detects pod failure
          │ │  - EndpointSlice controller: 5-10s propagates change
          │ │  - kube-proxy iptables sync: 1-2s
          │ │  - Internal scrapers → buffer-b (5-15s total)
          │ │  - External scrapers via NLB:
          │ │    * Health check: 2 failures × 5s interval = 10s
          │ │    * NLB removes targets, routes to buffer-b
          │ │  - buffer-b continues dual-write to (a, b)
          │ │  - vmagent_remotewrite_pending_data_bytes{url="vm-a-url"}
          │ │    starts growing on disk buffer
          │ └─ Read path (empirical RTO 5-15s)
          │    - Grafana pods → vmselect-b (kube-proxy fallback)
          │    - vmselect-b queries vmstorage-b (data replicated)
          │    - Query latency: +50-200ms (cold cache on vmselect-b)
          │    - Query freshness: <1s (normal) → <5min (during buffer drain)
T0:20     │ NLB fully removes AZ-A targets from rotation
T0:30     │ Stability achieved; write buffer growing at ~150 KB/s per pod
          │
T+1h      │ ┌─ Monitoring expectations
          │ │ - Alert: TopologyHintsInactive (if pod skew >3× silently disabled)
          │ │ - Alert: VmagentBufferHighFill (>70% of 50GB per pod)
          │ │ - Alert: VMStorageNodeUnavailable (if 1a vmstorage had data)
          │ │ - vmagent_remotewrite_pending_data_bytes{url="vm-a"} ≈ 540MB
          │ └─ Capacity: buffer-b pod CPU 60→90%, not throttled
          │
T+5d      │ Buffer near full (50GB × 3 pods = 150GB total per cluster)
          │ At this point: rate-limit kicks in (10MB/s drain when AZ recovers)
          │ Beyond 5d: oldest data dropped (FIFO)
          │
T_recovery│ AZ-1a restores → health checks pass within 10s
          │ EndpointSlice controller re-enables hints (5-10s)
          │ NLB re-adds AZ-A targets (10s)
          │ Pending buffer drains at -remoteWrite.rateLimit=50MB/s per URL
          │ Recovery time:
          │   - Empty buffer: <1 minute
          │   - Half-full (75GB): ~25 minutes
          │   - Full (150GB): ~50 minutes
          │ During recovery: queries stay on VM-B (no flip-flop)
```

> **Note on buffer numbers:** 50GB per pod × 3 pods per AZ × 2 AZs = 300GB total
> EBS provisioned. With `-remoteWrite.maxDiskUsagePerURL=45GiB` per URL,
> retention window: ~5 days at 150 KB/s sustained backpressure rate.

---

## Verification Checklist (Post-Migration)

```bash
# 1. Topology hints active
kubectl get endpointslices -n prod-itprod -o json | \
  jq '.items[] | select(.metadata.name | contains("vmselect")) | .hints'
# Expected: hints.forZones populated for each endpoint

# 2. Pod affinity correct
kubectl get pods -n prod-itprod -o wide | grep vmstorage
# Expected: vmstorage-a-0 on node in 1a, vmstorage-a-1 on node in 1a (different), etc.

# 3. PVCs in correct AZ
kubectl get pvc -n prod-itprod -o wide
# Expected: EBS volume zone matches pod's node zone

# 4. Pending buffer bytes near zero
kubectl exec -n prod-itprod <vmagent-buffer-a-0> -- \
  curl -s localhost:8429/metrics | grep vmagent_remotewrite_pending_data_bytes
# Expected: <1GB for each buffer pod

# 5. No partial responses
kubectl exec -n prod-itprod <vmselect-main-a-0> -- \
  curl -s localhost:8481/metrics | grep vm_partial_results_total | tail -1
# Expected: vm_partial_results_total 0

# 6. Duplicate check
promql: count by (job, instance) (up{cluster="atf01"}) > 1
# Expected: empty

# 7. Cross-AZ traffic (should be minimal, only dual-write)
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name NetworkOut \
  --dimensions Name=InstanceId,Value=<nlb-node-1a> \
  --statistics Sum \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300
# Expected: only vmagent-buffer cross-AZ write, vmselect local
```

---

## VM Component Flags

### vmstorage (All Instances, Both Clusters)

```
-dedup.minScrapeInterval=30s     # Scrape interval (min across all configs)
```

### vmselect-main (All Instances)

```
-dedup.minScrapeInterval=30s
-search.maxSamplesPerQuery=1000000000
-search.maxQueryDuration=120s
# NOT -search.denyPartialResponse=true (consistency = false during rolling upgrades)
```

### vmselect-alerts (All Instances)

```
-dedup.minScrapeInterval=30s
-search.maxSamplesPerQuery=1000000000
-search.maxQueryDuration=120s
# NOT -search.denyPartialResponse=true (alarms would all go to error state during upgrade)
```

### vmagent-buffer (Both Clusters)

```
# CORRECTED: 45GiB per URL (50GB pod buffer × 0.9 headroom for 2 URLs)
-remoteWrite.maxDiskUsagePerURL=45GiB

# Per-URL rate limit (NOT global — must be specified per URL)
# Format: -remoteWrite.url[N].streamAggrConfig with per-URL rate limit
# OR: -remoteWrite.maxRowsPerBlock=10000 on slow URL only
-remoteWrite.rateLimit=50MB                  # Global rate limit (applies to all URLs)

-remoteWrite.retryInterval=1s
-remoteWrite.dialTimeout=5s
-remoteWrite.readTimeout=5s
```

> **⚠️ IMPORTANT:** `-remoteWrite.rateLimit` is **per-vmagent**, not per-URL.
> To rate-limit only the cross-cluster URL (vminsert other cluster), use the
> per-URL form `-remoteWrite.url[N].rateLimit` (vmagent v1.95+) or limit
> via `streamAggrConfig` per URL.

---

## Cardinality Management (CRITICAL)

**At 111M active series + 90M churn/24h, cardinality is the primary scaling constraint.**

### Cardinality Budget Allocation

| Component | Active Series | Churn/Day | Notes |
|-----------|---|---|---|
| K8s metadata | 45M | 40M | kube_pod_info, kube_node_info, etc. |
| Game metrics | 55M | 45M | Per-game telemetry, custom labels |
| Infrastructure | 11M | 5M | Node-exporter, container_*, vmagent |
| **Total** | **111M** | **90M** | Budget headroom: 120% = 133M alert |

### Cardinality Alerts

```yaml
- alert: VMCardinalityBurstDetected
  expr: |
    sum by (cluster) (vmagent_active_series)
    > 1.2 * avg_over_time(sum by (cluster) (vmagent_active_series)[1d:1h])
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "{{ $value | humanize }} series spike on {{ $labels.cluster }}"
    action: "Investigate: new game deployment? Misconfigured high-cardinality label?"

- alert: VMCardinalityBudgetExceeded
  expr: sum by (cluster) (vmagent_active_series) > 1.2 * 111e6
  for: 30m
  labels:
    severity: critical
  annotations:
    summary: "Cardinality {{ $value | humanize }} exceeds 120% budget on {{ $labels.cluster }}"
    action: "Trigger aggressive relabeling or service discovery tuning"

- alert: VMHourlySeriesLimitHit
  expr: increase(vm_hourly_series_limit_rows_dropped_total[5m]) > 0
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Cardinality limit hit on {{ $labels.instance }}, series being dropped"
```

### Topology Hints — Proactive Monitoring

```yaml
# Fire BEFORE 3× threshold triggers silent deactivation
# Note: actual threshold per KEP-2433 is 20% endpoint-overload, not "3× skew"
# but skew correlates with overload; alerting on skew gives early warning
- alert: TopologyHintsInactivePreventive
  expr: |
    (max by (zone) (count by (zone, pod) (kube_pod_info{namespace="prod-itprod"}))
     /
     min by (zone) (count by (zone) (kube_node_info))
    ) > 2.5
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Pod distribution skew {{ $value | humanize }}× detected"
    action: "Manually rebalance pods or trigger descheduler before hints disable at 3×"

# Hard alert when hints actually deactivate
# Requires kube-state-metrics with --metric-annotations-allowlist=endpointslices=[*]
- alert: TopologyHintsDeactivated
  expr: |
    kube_endpointslice_annotations{
      annotation_service_kubernetes_io_topology_mode="Auto"
    } unless on (endpointslice)
    kube_endpointslice_annotations{annotation_hints_auto="yes"}
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Topology hints deactivated for {{ $labels.endpointslice }}"
    action: "Cross-AZ traffic restored. Check pod-to-node ratio + manual fix"
```

> **Prerequisite:** kube-state-metrics 2.x requires
> `--metric-annotations-allowlist=endpointslices=[*]` to expose annotation values.
> Without this, the alert above will never fire (returns empty result).

---

## EBS Tuning for vmstorage

```hcl
resource "aws_ebs_volume" "vmstorage" {
  size              = 2048   # 2 TiB
  type              = "gp3"
  iops              = 6000   # Baseline 3000 insufficient for compaction burst
  throughput        = 500    # MB/s; baseline 125 insufficient
  availability_zone = "us-east-1a"
  
  tags = {
    Name = "vmstorage-a-0"
  }
}
```

**Why 6000 IOPS, 500 MB/s?**
- 111M active series + 90M churn/24h
- Background compaction burst: 100-200 MB/s
- Baseline 3000 IOPS + 125 MB/s throttles → compaction debt → query latency degradation

**EBS gp3 cost (us-east-1, May 2026 — verified against AWS pricing page):**
```
Storage:    2048 GB × $0.08/GB-mo  = $163.84/vol-mo
IOPS:       (6000-3000) × $0.005   = $15.00/vol-mo  (3000 free)
Throughput: (500-125) × $0.04      = $15.00/vol-mo  (125 MB/s free)
Total:      $193.84/vol-mo per node
```
- Per cluster (10 nodes): **$1,938/month**
- Both clusters (20 nodes): **$3,877/month**
- This is *unchanged* vs. RF=2 baseline (same total node count)
- Earlier drafts cited "$56/volume" — that was wrong (missed full pricing components)

---

## DNS Aliases (in itprod-provisioning-projects)

```yaml
# app.yml
aliases:
  # Write path
  vm-write.local.playrix.com:        <write-nlb-dns>.elb.us-east-1.amazonaws.com
  vm-write.playrix.com:              <write-nlb-cdn-cname>  # External

  # Read path (main)
  vm-read.local.playrix.com:         <read-nlb-dns>.elb.us-east-1.amazonaws.com
  victoriametrics.local.playrix.com: <read-nlb-dns>.elb.us-east-1.amazonaws.com

  # Read path (alerts)
  vmselect-alert.local.playrix.com:  <read-nlb-dns>.elb.us-east-1.amazonaws.com

  # Read path (export/BI)
  vmselect-export.local.playrix.com: <export-nlb-dns>.elb.us-east-1.amazonaws.com
```

---

## Related Designs

- **Scraper Locality** — Zone-aware VMAgent architecture (`prometheus-scraper-locality.md`)
  - N VMAgent CRD per AZ
  - Zone-based relabeling
  - $534/month baseline, $1K/month activation threshold

---

## Runbooks

### Scale vmstorage disk (2Ti → 4Ti)

See [`vmstorage-volume-expand-to-2Ti.md`](../runbooks/vmstorage-volume-expand-to-2Ti.md)

### Migrate old RF=2 cluster to dual-cluster

Detailed 9-phase procedure in [`../victoria-metrics-cluster-stage/TODO-prod-migration.md`](../victoria-metrics-cluster-stage/TODO-prod-migration.md)

---

## Cost Breakdown (Monthly, Verified May 2026)

**Both clusters combined (us-east-1, on-demand pricing):**

| Item | Qty | Unit | Rate | Cost |
|------|-----|------|------|------|
| vmstorage EBS gp3 (2TB + 6K IOPS + 500MB/s) | 20 | volumes | $193.84/vol | $3,877 |
| vmstorage EC2 r7g.2xlarge (on-demand) | 20 | instances | $305/mo | $6,100 |
| vminsert EC2 r7g.large | 4 | instances | $76/mo | $304 |
| vmselect EC2 r7g.large | 6 | instances | $76/mo | $456 |
| vmagent-buffer EC2 r7g.large | 6 | instances | $76/mo | $456 |
| vmagent-buffer EBS gp3 (50GB) | 6 | volumes | $4/vol | $24 |
| NLB (3 NLBs × 3 zones) | 3 | lb | $16/mo | $48 |
| NLB capacity units (NLCU) | ~100 | NLCU | $0.0072/h | ~$520 |
| Cross-AZ egress (dual-write, both directions) | 1900 | GB | $0.02/GB | $1,900 |
| **Total** | | | | **~$13,685/month** |

> **Notes:**
> - Cross-AZ egress: AWS charges $0.01/GB **in each direction** (effective $0.02/GB on conversation)
> - Reserved instances (1yr no upfront) reduce EC2 costs by ~30% → save ~$2,200/mo
> - NLCU billing: charges per NLB capacity unit (NOT EBS DCU); ~$0.0072/NLCU-hour
> - vmstorage EC2 on-demand: r7g.2xlarge in us-east-1 = $305/mo (verified AWS pricing page May 2026)

**vs. RF=2 baseline (single cluster):**

| Item | RF=2 | Dual-Cluster | Delta |
|------|------|---|---|
| vmstorage EC2 (10 nodes) | $3,050 | $6,100 | +$3,050 |
| vmstorage EBS | $1,938 | $3,877 | +$1,939 |
| Cross-AZ read egress (fan-out) | $900 | $0 | -$900 |
| Cross-AZ write (dual-write) | $0 | $1,900 | +$1,900 |
| Other (vminsert, vmselect, NLB) | similar | similar | minimal |
| **Net delta** | | | **+$5,989/mo** |

> **⚠️ Honest framing:** Dual-cluster is **more expensive** in absolute terms
> (+$6K/mo) due to doubled storage. The "savings" come from:
> - Eliminated cross-AZ read egress (-$900/mo)
> - Avoided vmselect right-sizing to r7g.4xlarge (~$280/mo)
> - **Net cash savings: ~$320/mo** (modest)
> - **Real value: AZ-level DR + operational simplicity**
>
> Earlier drafts claimed "−$1,630/month" — that was incorrect. Honest accounting
> shows dual-cluster as a **DR investment**, not a cost reduction.

---

## References

- [Victoria Metrics Multi-AZ Architecture](https://docs.victoriametrics.com/guides/vm-architectures/#multi-cluster-and-multi-az)
- [VictoriaMetrics Distributed Chart](https://docs.victoriametrics.com/helm/victoriametrics-distributed/)
- [Kubernetes Topology-Aware Routing](https://kubernetes.io/docs/concepts/services-networking/topology-aware-routing/)
- [AWS NLB Cross-Zone Load Balancing](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/network-load-balancers.html#cross-zone-load-balancing)
- [Issue #4216 — Zone Awareness in Consistent Hash](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/4216)
- [Issue #8044 — Write Buffer Lost on Ingester Failure](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/8044)

---

## Contacts

- **Owner:** Playrix IT Production team
- **Slack:** #infra-vm
- **Runbooks:** See `docs/` directory
- **Metrics dashboard:** [Grafana — victoria-metrics-cluster-health](https://grafana.playrix.com/d/vm-cluster-health)
