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

## Pod Affinity Rules

### vmstorage Pods (Strict Isolation)

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
- Required = hard guarantee

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
  
  health_check {
    protocol            = "TCP"
    interval            = 10   # Fast failover
    healthy_threshold   = 2
    unhealthy_threshold = 2    # ~20s to failover
  }
}

# Register vmagent-buffer-a AND vmagent-buffer-b as targets
resource "aws_lb_target_group_attachment" "write_targets_a" {
  target_group_arn = aws_lb_target_group.write_targets.arn
  target_id        = aws_instance.vmagent_buffer_a.id
  port             = 8429
}

resource "aws_lb_target_group_attachment" "write_targets_b" {
  target_group_arn = aws_lb_target_group.write_targets.arn
  target_id        = aws_instance.vmagent_buffer_b.id
  port             = 8429
}
```

**Why `cross_zone_load_balancing = false`?**
- NLB has 3 nodes (one per AZ)
- NLB node in 1a only forwards to targets in 1a
- Client from 1a region → NLB node in 1a → buffer pod in 1a
- Automatic locality, no cross-AZ on write path buffer layer

**NLB TCP idle timeout = 350s (hardcoded, immutable):**
- Graphite clients idle > 350s → RST without warning
- Check before deployment: all Graphite clients must support `SO_KEEPALIVE` with interval < 300s

---

## Failover Sequence

### Scenario: us-east-1a AZ Outage (Duration: T0 to T0+5min)

```
T0:00    │ Packet loss begins; kube-probe fails
T0:05    │ ┌─ Write path
         │ │   - Internal scraper → kube-proxy topology fallback
         │ │     → buffer-b (automatic, <100ms)
         │ │   - External scraper → NLB health check
         │ │     → marks buffer-a targets unhealthy (2s delay)
         │ │     → routes to buffer-b
         │ │   - buffer-b continues dual-write a,b
         │ │   - vmagent_remotewrite_pending_data_bytes[a] starts growing
         │ └─ Read path
         │     - Grafana pods → kube-proxy topology fallback
         │       → vmselect-b (automatic, <100ms)
         │     - vmselect-b queries vmstorage-b (all data replicated)
         │     - Queries succeed, latency +50ms (cross-pod communication)
T0:20    │ NLB removes AZ-A targets from rotation (health check failures)
T0:30    │ Stability: write buffer ~ 50GB (1 hour at 920K samples/s)
         │
T1:00    │ ┌─ Monitoring
(5 min)  │ │ - Alerts: `TopologyHintsInactive` (if hints silently disabled)
         │ │ - Alerts: `VmagentBufferHighFill` (>70% of 200GB)
         │ │ - Alerts: `VMStorageNodeUnavailable` (if 1a node had data)
         │ │ - vmagent_remotewrite_pending_data_bytes_total[vminsert_url=vm-a] = ~200GB
         │ └─ Capacity: buffer-b pod CPU 60→90%, not throttled
         │
T_recovery│ AZ-1a restores → health checks pass
          │ NLB re-adds AZ-A targets
          │ Pending buffer for vm-a drains (~5 days retention if outage >5d)
          │ ~30 minutes to full capacity
```

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
-remoteWrite.maxDiskUsagePerURL=180GiB       # Isolate per URL
-remoteWrite.rateLimit=50MB                  # Only for cross-AZ (vminsert other cluster)
-remoteWrite.retryInterval=1s                # Retry immediately
-remoteWrite.dialTimeout=5s
-remoteWrite.readTimeout=5s
```

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
- Cost delta: ~$56/volume/month → $560/month per cluster (acceptable vs. query slowdown)

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

## Cost Breakdown (Monthly)

| Item | Qty | Unit | Rate | Cost |
|------|-----|------|------|------|
| vmstorage EBS gp3 (2TB @ 6K IOPS, 500MB/s) | 20 | volumes | $56.00 | $1,120 |
| vmstorage EC2 r7g.2xlarge | 20 | instances | $280/mo | $5,600 |
| vminsert EC2 | 4 | instances | $50 | $200 |
| vmselect EC2 | 6 | instances | $50 | $300 |
| vmagent-buffer EC2 | 6 | instances | $50 | $300 |
| NLB (3 zones) | 1 | lb | $16 | $16 |
| NLB capacity units (data processing) | 50 | DCU | $0.01 | $500 |
| Cross-AZ egress (dual-write only) | 950 | GB | $0.01 | $950 |
| **Total** | | | | **~$9,086/month** |

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
