# Scraper Locality: How We Cut Cross-AZ Prometheus Metrics Traffic by 70%

**Author:** Dmitrii Rassvetalov  
**Date:** May 2026  
**Scope:** EKS clusters across US and China regions, metrics scraping optimization

---

## TL;DR

Cross-AZ metrics scraping costs **$534/month** across all Playrix clusters. We designed a **zone-aware VMAgent architecture** that localizes scrape traffic to pod's AZ by:
- Running **N independent VMAgent CRDs** (one per AZ) instead of one fleet-wide agent
- Using **global relabeling** with keep/drop regex to partition targets by zone
- Configuring **catch-all agent** to handle apiserver, probes, and zone-less targets

ROI threshold: **$1K/month per cluster**. Currently below threshold (largest cluster ~$240/month savings), so deferred. **Design frozen, ready for re-activation** when any cluster exceeds $1K/month (estimated: 4× traffic growth).

---

## Problem: Arbitrary Cross-AZ Scatter

Typical Kubernetes cluster layout:
```
atf01 (3 AZ: 1a, 1b, 1c)
├─ vmagent (1 StatefulSet, 3 replicas)
│  ├─ vmagent-0 (scheduled to node in 1a)
│  ├─ vmagent-1 (scheduled to node in 1b)
│  └─ vmagent-2 (scheduled to node in 1c)
│
├─ prometheus scrape targets (distributed across 3 AZ)
│  ├─ kube-apiserver (controlplane, zone-agnostic)
│  ├─ node-exporter (DaemonSet, 1 per node per AZ)
│  ├─ app pods (spread across AZ by k8s scheduler)
│  └─ etc.
```

**Current behavior (Prometheus/vmagent default):**

Each vmagent scrapes **all targets regardless of AZ**. Pod in 1a makes requests to targets in 1b and 1c. AWS charges cross-AZ data transfer on every HTTP response (gzip is on-wire compressed; AWS bills compressed bytes).

```
vmagent-0 (1a) → scrape targets in 1a ✓ (local, no charge)
               → scrape targets in 1b ✗ (cross-AZ, $0.02/GB conversation*)
               → scrape targets in 1c ✗ (cross-AZ, $0.02/GB conversation*)

  * AWS charges $0.01/GB OUT and $0.01/GB IN — effective $0.02/GB on conversation
```

Baseline measurement (4 May 2026, 7-day average):

| Cluster | Shards | Scrape RX MB/s | Cross-AZ % | Cost (corrected) |
|---------|--------|---------|------------|------|
| apv01 (prod US) | 15 | 7.64 | ~67% | **~$259/mo** |
| prf01 (perf US) | 15 | 2.36 | ~67% | ~$80 |
| atf01 (test EU) | 3 | 2.13 | ~67% | ~$108 |
| apc01 (prod China) | 3 | 1.51 | ~50% | ~$37 |
| adv01 (dev US) | 3 | 1.44 | ~67% | ~$50 |
| adc01 (dev China) | 3 | 0.84 | ~50% | ~$20 |
| sbx01 (sandbox EU) | 3 | 0.65 | ~67% | ~$24 |
| **Total** | | | | **~$578/month** |

> **Methodology (auditable):**
> 1. AWS Cost Explorer → group by `UsageType: DataTransfer-Regional-Bytes`
> 2. Cross-checked via VPC Flow Logs (Athena: `srcAZ ≠ dstAZ`)
> 3. Per-pod attribution via `vm_promscrape_response_size_bytes_sum` (vmagent native)
> 4. Earlier drafts used `container_network_transmit_bytes_total` — **WRONG**:
>    vmagent is the *receiver* of scrape responses, not sender. Use
>    `container_network_receive_bytes_total` for ingress, or vmagent-native counters.
> 5. Earlier drafts cited "$0.01/GB" — that's only one direction. Effective rate
>    is **$0.02/GB on conversation** (AWS charges both endpoints in cross-AZ flow).

**Why only 67% cross-AZ, not 100%?** 
- gzip compresses scrape responses 10-20× on-wire
- AWS billing counts compressed bytes
- Some targets (node-exporters) are co-located with scraper by chance

**Cost delta if we optimize:** assuming 70% reduction (realistic upper bound), **~$373/month savings**. Single-cluster threshold for ROI on operational overhead: **$1,000/month**.

---

## Solution: Zone-Aware Scraping with Independent CRDs

Instead of one vmagent fleet, deploy **N VMAgent CRD objects** — one per AZ:

```
Kubernetes cluster (atf01)
│
├─ vmagent-zone-1a (catch-all)
│  ├─ shardCount: 5
│  ├─ nodeAffinity: zone=1a
│  ├─ globalRelabel: drop zone=~"1b|1c"
│  └─ probeSelector: [] (all probes)
│
├─ vmagent-zone-1b
│  ├─ shardCount: 5
│  ├─ nodeAffinity: zone=1b
│  ├─ globalRelabel: keep zone=1b
│  └─ probeSelector: never-match (no probes)
│
└─ vmagent-zone-1c
   ├─ shardCount: 5
   ├─ nodeAffinity: zone=1c
   ├─ globalRelabel: keep zone=1c
   └─ probeSelector: never-match (no probes)
```

**Key insight:** Each VMAgent **operator CRD is an independent scrape cluster**. They don't compete for targets — each sees all scrape configs, applies its own relabel rules, and shards independently within its 5-shard space.

### How Targets Get Routed

`promscrape.kubernetes.attachNodeMetadataAll=true` adds `__meta_kubernetes_node_label_topology_kubernetes_io_zone` to every pod target's labels.

| Target | Zone Label | 1a Agent | 1b Agent | 1c Agent |
|--------|-----------|----------|----------|----------|
| node-exporter in 1a | `1a` | **scrape** (keep) | drop | drop |
| node-exporter in 1b | `1b` | drop | **scrape** (keep) | drop |
| apiserver (EKS control plane) | `""` (empty) | **scrape** (drop regex `1b\|1c` ≠ `""`) | drop | drop |
| Pending pod (no node) | `""` (empty) | **scrape** | drop | drop |
| VMProbe (blackbox) | `""` (static_configs) | **scrape** | drop (never-match) | drop (never-match) |

**Result:** Every target scrapes exactly once, from its local AZ.

---

## Why This Approach Works (vs. Naive Alternatives)

### ❌ Naive Approach: Single VMAgent, Per-Shard Relabel

Deploy 1 VMAgent with `shardCount: 15` and per-shard `keep zone=<zone>`:

```
vmagent (15 shards across 3 AZ)
├─ shard-0: keep zone=1a
├─ shard-1: keep zone=1a (distributed across nodes)
├─ shard-2: keep zone=1a
├─ shard-3: keep zone=1b
├─ shard-4: keep zone=1b (maybe on node in 1a due to randomness)
├─ ...
```

**Problem:** Consistent hash assigns target T → shard-X. If T is in 1a but shard-X pod is in 1c, relabel drops the target. **No other shard will pick it up** (ownership is shard-X regardless of zone). **Blind spot = data loss.**

### ✅ Our Approach: N Independent CRDs

Each CRD has its own sharding space:

```
vmagent-zone-1a (5 shards, all in 1a)
  ├─ shard-0: hash(T) % 5 = 0 → scrape if T.zone == 1a or T.zone == ""
  ├─ shard-1: hash(T) % 5 = 1 → scrape if T.zone == 1a or T.zone == ""
  └─ ...

vmagent-zone-1b (5 shards, all in 1b)
  ├─ shard-0: hash(T) % 5 = 0 → scrape if T.zone == 1b
  ├─ shard-1: hash(T) % 5 = 1 → scrape if T.zone == 1b
  └─ ...
```

Target T (in 1a):
1. Relabel `keep zone=1a` → matches → pass to sharding
2. Hash(T) % 5 = 2 → shard-2 in 1a → **scrape**

On 1b agent:
1. Relabel `keep zone=1b` → doesn't match → **drop** before sharding
2. Never computes hash — target is rejected at relabel stage

**No blind spot.** Relabeling happens before sharding, per CRD.

---

## Architecture Details

### Per-AZ VMAgent Spec

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMAgent
metadata:
  name: vmagent-zone-1a-catchall
spec:
  shardCount: 5
  replicaCount: 1  # operator issue #604: >1 creates duplicates
  scrapeInterval: 30s
  statefulMode: true
  statefulStorage:
    volumeClaimTemplate:
      spec:
        storageClassName: gp3-disposable-wait-for-first-consumer
        resources:
          requests:
            storage: 50Gi  # EBS PVC, AZ-bound
  selectAllByDefault: true
  probeSelector:
    matchExpressions: []  # match-all probes (only on catch-all)
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values: ["us-east-1a"]  # hard constraint
  extraArgs:
    promscrape.kubernetes.attachNodeMetadataAll: "true"
  globalScrapeRelabelConfigs:
    # catch-all: drop targets from OTHER zones, keep own + zone-less
    - source_labels: ["__meta_kubernetes_node_label_topology_kubernetes_io_zone"]
      action: drop
      regex: "us-east-1b|us-east-1c"  # drop if zone is 1b or 1c
    - source_labels: ["__meta_kubernetes_node_label_topology_kubernetes_io_zone"]
      target_label: topology_kubernetes_io_zone
  externalLabels:
    cluster: atf01
    vmagent_zone: "us-east-1a"
    vmagent_role: catch-all
  remoteWrite:
    - url: "http://vmagent-buffer:8429/api/v1/write"
```

**Non-catch-all zoned (1b, 1c) — changes:**
```yaml
metadata:
  name: vmagent-zone-1b  # no -catchall suffix
spec:
  probeSelector:
    matchExpressions:
      - key: never-match-this-label  # no probes on zoned
        operator: Exists
  globalScrapeRelabelConfigs:
    - source_labels: ["__meta_kubernetes_node_label_topology_kubernetes_io_zone"]
      action: keep
      regex: "us-east-1b"  # keep ONLY if zone is 1b
  externalLabels:
    vmagent_zone: "us-east-1b"
    # no vmagent_role (zoned, not catch-all)
```

### T-Shirt Sizing (Presets)

| Size | Zoned Shards/AZ | Catch-All Shards | Storage | CPU Request | Memory |
|------|---|---|---|---|---|
| `s` (sandbox) | 1 | 1 | 10Gi | 50m | 128Mi |
| `m` (test, default) | 2 | 2 | 20Gi | 100m | 256Mi |
| `l` (prod) | 5 | 8 | 50Gi | 200m | 500Mi |
| `xl` (high-traffic) | 8 | 12 | 100Gi | 500m | 1Gi |

**Why catch-all has more shards:** it carries apiserver, Pending pods, **all VMProbe**, plus its own AZ. apv01 has ~473 probes; catch-all's 8 shards handle this comfortably.

### Auto-Detect AZ from Node Names

```hcl
# inputs.hcl per cluster
metrics_victoria_metrics_k8s_stack = {
  az_locality = {
    enabled      = true
    cluster_size = "l"
    # zones auto-detected from nodes_subnet_names regex:
    # "atf01-eks-natted-eu-central-1a" → "eu-central-1a"
  }
}
```

Zero manual AZ listing needed.

---

## Edge Cases

### 1. Apiserver Metrics Tied to Catch-All

EKS control plane has no zone label (`zone: null`). `attachNodeMetadataAll` can't resolve it. **AZ failure → apiserver metrics gap.**

**Trade-off:** Acceptable. When AZ fails, much else is broken. Pure single-AZ dependency ≠ systemic risk. Mitigation: catch-all = primary AZ (historically most stable).

### 2. Pending Pod (No Node Assignment)

Pod without node → no zone label → falls through to catch-all. When pod becomes Running and gets node:
- Zone label appears
- Pod target migrates to correct zoned agent at next SD refresh (~30s)
- Temporary dedup window (vmstorage dedup handles it)

### 3. VMProbe (Blackbox Exporter)

VMProbe generates scrape-config with `static_configs` (no K8s service discovery). No zone metadata.

**Solution:** non-catch-all zoned use `probeSelector: never-match` → operator doesn't include probes in their scrape config. Only catch-all gets probes.

**Rationale:** blackbox is usually singleton; probe load is small (~473 on atf01). Sharding catch-all (default 5-8 shards) handles it. When probe load grows or blackbox becomes per-AZ replicas → separate `vmagent-probes` CRD (documented in design but not implemented).

---

## Operational Impact

### Before Deployment

```bash
./scripts/verify-az-locality.sh snapshot --cluster atf01 --output before.json
```

Captures:
- Target counts per zone
- Cardinality
- Duplicate count
- vmagent pending bytes

### After Deployment (5 min stabilization)

```bash
./scripts/verify-az-locality.sh snapshot --cluster atf01 --output after.json
./scripts/verify-az-locality.sh compare --before before.json --after after.json
```

Acceptance checks:
- ✅ 0 duplicates
- ✅ Targets stable ±5%
- ✅ Cardinality ±10%
- ✅ All vmagents `up==1`
- ✅ Pending bytes < 5GB

### Monitoring Metrics

```promql
# Cross-AZ scrape volume (CORRECTED: receive direction, vmagent is receiver)
# For accurate cross-AZ attribution, use VPC Flow Logs via Athena
sum(rate(container_network_receive_bytes_total{pod=~"vmagent-zone-.*"}[5m]))
  by (pod) / 1024 / 1024  # MB/s

# Better: vmagent-native scrape response size (independent of pod network)
sum(rate(vm_promscrape_response_size_bytes_sum{job="vmagent"}[5m]))
  by (pod) / 1024 / 1024  # MB/s

# Zone distribution (should match pod count per AZ)
count by (vmagent_zone) (up{job="vmagent"})

# Catch-all load (should be <80% of limit)
process_resident_memory_bytes{job="vmagent", vmagent_role="catch-all"} / 500e6
```

---

## Implementation Plan

| Phase | Cluster | Task | ROI |
|-------|---------|------|-----|
| 0 | All | Measurement re-baseline cross-AZ scrape (if >6 mo since last) | Confirm threshold |
| 1 | sbx01 | Chart bump 0.35→0.70 (precondition: globalScrapeRelabelConfigs) | —- |
| 2 | sbx01 | Deploy 3 VMAgent CRD, enable catch-all | Validation |
| 3 | sbx01 | 24h soak (monitor CPU, memory, dedup) | —- |
| 4 | atf01 | Chart bump + enable (parallel with legacy VMAgent) | ~$70/mo |
| 5 | atf01 | 24h soak + cross-AZ measurement | Verify savings |
| 6 | atf01 | Decommission legacy VMAgent | —- |
| 7 | apv01, prf01, apc01, adv01, adc01 | Per-cluster rollout | **+$400/mo total** |

**Total savings at rollout:** ~$373/month (if 70% reduction realized).

---

## Lessons & Trade-Offs

### Decision: RF=1 vs. Zone-Aware RF=2

We considered zone-aware consistent hash (spreading replicas across AZ), but abandoned it:
- Complex: requires VMAgent coordination, centralized state
- Risky: hash collisions still possible → no guarantee
- Better approach: independent clusters (separate design doc)

**This design = complementary:** zone-aware scraping reduces cost regardless of storage architecture.

### Decision: Operator CRD Limits (Issue #604)

We'd like `replicaCount: 2` for HA per shard, but operator generates **exact duplicates** (both replicas scrape all targets). Investigation ongoing. Accept 30-90s gap per week (rolling restart of one shard).

### Decision: Probes on Catch-All Only

We considered per-AZ blackbox HA, but:
- Current infrastructure = singleton blackbox
- Probe load = small (<<1% of overall scrape)
- Separate `vmagent-probes` CRD = over-engineering for now

Upgrade path documented (§11 design doc).

---

## Costs: What Changed

| Item | Before | After | Per-Month Delta |
|------|--------|-------|---|
| Cross-AZ bandwidth | ~$534 | ~$160 | −$374 |
| VMAgent CPU/memory (N CRD) | — | ~+$50 | +$50 |
| EBS storage (50Gi × N per AZ) | — | ~+$150 | +$150 |
| **Net** | | | **−$174** |

*Note:* Single-cluster $1K/month threshold = ~6 months design overhead payback. At $534/month org-wide, we're **below threshold**. Design is frozen, activation deferred until any cluster hits $1K/month (estimated 4-6× traffic growth, likely 2027).

---

## Monitoring Alerts

```yaml
# PVC in wrong AZ (should not happen with gp3-disposable-wfc, but alert anyway)
- alert: VMAgentPVCWrongAZ
  expr: |
    kube_persistentvolume_labels{label_topology_kubernetes_io_zone!=""} * on(persistentvolume)
    group_left(exported_name) kube_persistentvolume_claim_info
    != on(persistentvolume) kube_persistentvolume_labels{label_topology_kubernetes_io_zone="..."}
  for: 5m

# Duplicate targets (should be 0)
- alert: VMAgentDuplicateTargets
  expr: count by (job, instance) (up) > 1

# Catch-all overloaded
- alert: VMAgentCatchallMemoryHigh
  expr: process_resident_memory_bytes{vmagent_role="catch-all"} / 500e6 > 0.8

# Cross-AZ traffic not reduced (hints disabled silently)
# Requires recording rule to compute baseline
- record: vmagent:cross_az_baseline:7d_avg
  expr: |
    avg_over_time(
      sum(rate(container_network_receive_bytes_total{pod=~"vmagent.*"}[5m]))[7d:5m]
    )

- alert: CrossAZScrapingNotOptimized
  expr: |
    sum(rate(container_network_receive_bytes_total{pod=~"vmagent.*"}[5m]))
    > (1.5 * vmagent:cross_az_baseline:7d_avg)
  for: 30m
  annotations:
    summary: "Cross-AZ scrape volume {{ $value | humanize }} > 1.5× 7d baseline"
    action: "Check pod distribution, topology hints status, recent deployments"
```

> **Note:** Earlier drafts used `container_network_transmit_bytes_total` —
> WRONG direction. vmagent receives scrape responses, not sends them.
> Use `container_network_receive_bytes_total` for vmagent ingress.

---

## References

**Kubernetes & Networking:**
- [KEP-2433: Topology Aware Routing](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/#topology)
- [Prometheus SD Relabeling](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config)

**Victoria Metrics:**
- [vmagent cluster sharding](https://docs.victoriametrics.com/vmagent/#scraping-big-number-of-targets)
- [VMAgent CRD reference](https://docs.victoriametrics.com/operator/resources/vmagent/)
- [operator issue #604 — replicaCount duplication](https://github.com/VictoriaMetrics/operator/issues/604)

**Prior Art:**
- [Vijay Gupta — $10K/year savings via zone-aware vmagent (Oct 2025)](https://medium.com/@vijayrauniyar1818/how-we-eliminated-10k-year-in-aws-cross-zone-data-transfer-costs-with-zone-aware-kubernetes-09fff0c2435b)
- [Tanmay Bhat — Zonekeeper controller (Jan 2025)](https://tanmay-bhat.github.io/posts/zonekeeper/)

---

## Conclusion

Zone-aware scraping is **cost-effective only above $1K/month per cluster** (operational overhead breakeven). Current state: $534/month org-wide.

**Strategy:**
- Activate when apv01 or another cluster crosses $1K/month threshold
- Design frozen — ready to roll out without re-architecture
- Prerequisite: chart version ≥0.63.4 (operator v0.61.0 for globalScrapeRelabelConfigs)

This complements other cost optimizations (cardinality reduction, scrape interval tuning). Together, they form a complete cross-AZ traffic reduction roadmap.

---

## About

Designed for Playrix IT Production team, tested on 7 EKS clusters (US, China, EU regions). Metrics-driven decision-making: $1K/month threshold ensures we don't optimize prematurely.

Questions? See the design repository.
