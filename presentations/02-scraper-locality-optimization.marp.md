---
marp: true
theme: gaia
class: lead
paginate: true
backgroundColor: #fff
header: 'Scraper Locality · Playrix IT Production'
footer: 'Dmitrii Rassvetalov · KubeCon EU 2026'
style: |
  section {
    font-family: 'Inter', sans-serif;
    font-size: 28px;
  }
  section.lead h1 {
    color: #ff6f00;
    font-size: 56px;
  }
  section.lead h2 {
    color: #555;
    font-size: 32px;
    font-weight: 400;
  }
  h1 { color: #ff6f00; }
  h2 { color: #333; border-bottom: 3px solid #ff6f00; padding-bottom: 8px; }
  table { font-size: 22px; margin: auto; }
  th { background: #ff6f00; color: white; }
  tr:nth-child(even) { background: #fff8e1; }
  code { background: #f0f0f0; padding: 2px 6px; border-radius: 4px; }
  pre { background: #263238; color: #eeffff; padding: 16px; border-radius: 8px; font-size: 20px; }
  blockquote {
    border-left: 5px solid #1976d2;
    background: #e3f2fd;
    padding: 12px 20px;
    font-style: normal;
  }
  .columns { display: grid; grid-template-columns: 1fr 1fr; gap: 32px; }
  .columns-3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 24px; }
  .big-number { font-size: 96px; color: #ff6f00; font-weight: bold; text-align: center; }
  .savings { color: #2e7d32; font-weight: bold; }
  .cost { color: #c62828; font-weight: bold; }
  .roi-box {
    background: #fff8e1;
    border: 3px solid #ff6f00;
    padding: 20px;
    border-radius: 8px;
    text-align: center;
  }
  .key-insight {
    background: #e3f2fd;
    border-left: 5px solid #1976d2;
    padding: 16px 24px;
    border-radius: 4px;
    font-size: 24px;
  }
---

<!-- _class: lead -->
<!-- _paginate: false -->

# Scraper Locality
## Когда $578/мес становится проблемой

**Dmitrii Rassvetalov**
IT Production · Playrix
KubeCon EU 2026 · FinOps Track

---
**7 кластеров** · ~$578/мес cross-AZ scrape baseline · ROI Discipline

> *"Не всё, что можно оптимизировать, нужно оптимизировать СЕЙЧАС."*

---

## Главная Мысль (теперь, чтобы не ждать конца)

<div class="roi-box">

### 📊 Текущее состояние
$578/мес org-wide cross-AZ scrape (7 кластеров)
**Самый большой:** apv01 = $259/мес (ниже $1K threshold)

### 💡 Дизайн готов, не deployed
**Trigger:** когда любой кластер перейдёт **$1K/мес**

### 🎓 Главный урок
**ROI discipline > implementation excitement**

</div>

> Этот доклад — про **измерение и timing**, не про optimization.

---

## Baseline: Где Живёт Cross-AZ Трафик?

| Кластер | Shards | Scrape RX | Cross-AZ % | $ Cost/мо |
|---|:-:|:-:|:-:|---:|
| **apv01** (prod US) | 15 | 7.64 MB/s | ~67% | **~$259** ⚠️ |
| prf01 (perf US) | 15 | 2.36 MB/s | ~67% | ~$80 |
| atf01 (test EU) | 3 | 2.13 MB/s | ~67% | ~$108 |
| apc01 (prod China) | 3 | 1.51 MB/s | ~50% | ~$37 |
| adv01 (dev US) | 3 | 1.44 MB/s | ~67% | ~$50 |
| adc01, sbx01 | 3 | 1.49 MB/s | ~58% | ~$44 |
| **Total** | | | | **~$578/mo** |

> **Methodology:** AWS Cost Explorer + VPC Flow Logs (Athena). Verified 7-day avg.
> **Rate:** $0.02/GB on conversation (in + out, AWS billing reality)

---

## Почему 67%, а не 100%?

```mermaid
graph LR
    subgraph "Random pod placement"
        P[vmagent pod в 1a]
        P -->|33% local| T1[targets в 1a ✅]
        P -->|33% cross-AZ| T2[targets в 1b ❌]
        P -->|33% cross-AZ| T3[targets в 1c ❌]
    end
    style T1 fill:#c8e6c9
    style T2 fill:#ffcdd2
    style T3 fill:#ffcdd2
```

**Kubernetes scheduler не знает про AZ.**
Default kube-proxy round-robin → vmagent в любой AZ → 67% targets cross-AZ.

> **Compression note:** gzip уменьшает on-wire bytes 5-10×, AWS bills compressed.
> Real wire bandwidth: ~32% от raw scrape data.

---

## ❌ Naive Решение — Blind Spot!

```mermaid
graph LR
    T[Target T в AZ-1a] --> SD[Service Discovery]
    SD --> Hash{Consistent Hash<br/>15 shards}
    Hash -->|hash% 15 = 12| S12[shard-12 в AZ-1c]
    S12 --> RL{relabel:<br/>keep zone=1c}
    RL -->|T.zone=1a ≠ 1c| Drop[❌ DROPPED]
    Drop -.-> Lost[💥 TARGET LOST<br/>никакой shard не возьмёт]
    style Drop fill:#ffcdd2
    style Lost fill:#ff5252,color:#fff
```

**Cluster ownership** = shard-12 владеет target T (по hash).
**Relabel дропает T до scraping.**
Никакой другой shard не возьмёт T → **blind spot**.

---

## ✅ Правильное Решение — N Independent CRDs

```mermaid
graph TB
    T[Target T в AZ-1a] --> SD[Service Discovery]
    SD --> CRD_A[VMAgent-zone-1a CRD]
    SD --> CRD_B[VMAgent-zone-1b CRD]
    SD --> CRD_C[VMAgent-zone-1c CRD]
    
    CRD_A --> RL_A{relabel:<br/>drop zone≠1a}
    RL_A -->|T.zone=1a PASS| Hash_A{hash mod 5}
    Hash_A --> Scrape_A[✅ scraped<br/>в 1a]
    
    CRD_B --> RL_B{relabel:<br/>drop zone≠1b}
    RL_B -->|T.zone=1a DROP| End_B[❌ before sharding]
    
    style Scrape_A fill:#c8e6c9
    style End_B fill:#fff3e0
```

**Каждый CRD = независимое sharding пространство.**
Relabel **до** sharding = no blind spots. ✅

---

## Архитектура: 3 CRD per Cluster

```mermaid
graph TB
    subgraph K8s["Kubernetes Cluster (3 AZ)"]
        subgraph A["AZ-1a (catch-all)"]
            VA[vmagent-zone-1a-catchall<br/>5 shards]
        end
        subgraph B["AZ-1b"]
            VB[vmagent-zone-1b<br/>5 shards]
        end
        subgraph C["AZ-1c"]
            VC[vmagent-zone-1c<br/>5 shards]
        end
        
        T1[targets в 1a] --> VA
        T2[targets в 1b] --> VB
        T3[targets в 1c] --> VC
        
        APIServer[apiserver<br/>VMProbes<br/>Pending pods] -.empty zone.-> VA
    end
    
    VA --> Buf[vmagent-buffer]
    VB --> Buf
    VC --> Buf
    
    style A fill:#fff8e1
    style B fill:#e3f2fd
    style C fill:#f3e5f5
```

**Catch-all** забирает targets без zone label (apiserver, probes, orphans)

---

## T-Shirt Sizing

| Size | Zoned Shards | Catch-All | Storage | CPU | Memory | Use Case |
|:-:|:-:|:-:|:-:|:-:|:-:|---|
| **s** | 1 | 1 | 10Gi | 50m | 128Mi | sandbox, dev |
| **m** | 2 | 2 | 20Gi | 100m | 256Mi | test, mid-prod (default) |
| **l** | 5 | **8** | 50Gi | 200m | 500Mi | typical prod |
| **xl** | 8 | **12** | 100Gi | 500m | 1Gi | high-traffic prod |

```hcl
# Activation = 3 lines в inputs.hcl:
metrics_victoria_metrics_k8s_stack = {
  az_locality = { enabled = true, cluster_size = "l" }
}
```

> **Auto-detect AZ** через regex по `nodes_subnet_names`. Zero manual config.

---

## Edge Case: Catch-All AZ

**Targets без zone label** = `apiserver`, `VMProbe`, Pending pods

```mermaid
graph LR
    T_orphan[Target без zone label] --> CRD_A[catch-all CRD в 1a]
    T_orphan --> CRD_B[zoned 1b CRD]
    T_orphan --> CRD_C[zoned 1c CRD]
    
    CRD_A --> RL_A{drop zone=~1b\|1c}
    RL_A -->|empty не матчит| Pass[✅ PASS]
    Pass --> Scrape[scraped]
    
    CRD_B --> RL_B{keep zone=1b}
    RL_B -->|empty не матчит| Drop_B[❌]
    
    style Pass fill:#c8e6c9
    style Scrape fill:#c8e6c9
```

**Trade-off:** AZ-1a outage = gap в apiserver/probe metrics на ~5 мин.
Acceptable: при AZ outage есть проблемы поинтереснее.

---

## ROI Анализ: Делать ИЛИ Ждать?

<div class="columns">

<div class="roi-box">

### 🔴 ROI СЕЙЧАС
**Savings:** ~$405/мес (70% reduction)
**Investment:** ~$10K (design + rollout)
**Payback:** **~25 месяцев**

❌ Слишком долго

</div>

<div class="roi-box">

### 🟢 ROI КОГДА $1K/мес
**Savings:** ~$700/мес
**Investment:** ~$10K (design ready)
**Payback:** **~14 месяцев**

✅ Reasonable

</div>

</div>

> **Trigger:** ANY cluster crosses **$1K/мес** baseline (quarterly review).
> **Estimate:** apv01 hits $1K при ~4× cardinality growth → likely 2027.

---

## Альтернатива: Cardinality Reduction (Лучше ROI)

| Optimization | Savings | Investment | Payback |
|---|---:|---:|:-:|
| **Drop unused labels** | $100/мес | $1K (1 sprint) | **3 мес** ✅ |
| **Increase scrape interval** (15s→30s) | $50/мес | $0.5K | **2 мес** ✅ |
| Scraper locality (deferred) | $405/мес | $10K | 25 мес ❌ |

<div class="key-insight">

🎯 **HIGH-ROI первыми.**
Cardinality reduction даёт быстрый payback СЕЙЧАС.
Scraper locality — для будущего, когда trigger threshold перейдёт.

</div>

---

## Activation Roadmap (когда $1K/мес crosses)

```mermaid
gantt
    title Activation Plan (4 phases × ~1 week)
    dateFormat X
    axisFormat Wk%w
    
    section Phase 1
    Re-baseline cross-AZ      :0, 7
    
    section Phase 2  
    Chart bump 0.35→0.70      :7, 10
    Sandbox validation (sbx01) :10, 17
    24h soak test              :15, 17
    
    section Phase 3
    Parallel deploy (10%)      :17, 19
    Gradual: 25→50→75→100%     :19, 24
    
    section Phase 4
    Decommission old vmagent   :24, 28
    Verify 70% reduction       :26, 28
```

**Total: ~1 month operational effort** (parallel deployment + safety buffer)

---

## Operational Gotchas

<div class="columns">

<div>

### ⚠️ Operator Issue #604
- `replicaCount > 1` = duplicate scrapes
- Accept: 30-90s gap per shard rolling restart
- Mitigate when probe-load grows

### ⚠️ Cardinality Burst
- Новая игра = +50M series overnight
- Dual-write means pay 2× for cardinality
- Alert: >20% rise in 5min

</div>

<div>

### ⚠️ Static Configs
- Custom scrape configs без zone label
- Falls through to catch-all
- Audit before rollout

### ⚠️ Network Policies
- Strict policies block cross-AZ
- Test: `kubectl exec → curl other AZ`
- Common pitfall after rollout

</div>

</div>

---

## Comparison: Single vs N AZ-Aware Agents

| Аспект | Single Agent | N AZ-Aware Agents |
|---|---|---|
| Deployment | 1 StatefulSet | N CRD (3 для 3 AZ) |
| Cross-AZ cost | ~$578/мес | ~$170/мес (70% save) |
| Pod scheduling | Random across AZ | nodeAffinity per AZ |
| **Failover на pod** | 30-60s (другой shard) | 30-60s (внутри той же AZ) |
| **Failover на AZ** | ✅ Other AZ продолжит | ❌ Targets-в-той-AZ STOP |
| **Resilience** | 🟢 **Higher** (AZ loss redistributes) | 🟡 Lower (catch-all SPOF) |
| ROI threshold | n/a | **$1K/мес per cluster** |

<div class="key-insight">

🎯 **Honest trade-off:** Cost savings ↔ AZ failure resilience.
Single agent = резильентнее. N agents = дешевле (когда подходит ROI).

</div>

---

## "Почему ждём?" — Хороший Вопрос

```mermaid
graph LR
    A[Сейчас:<br/>$578/мес savings × 7 clusters] --> B{ROI Math}
    B --> C[Investment: $10K<br/>Payback: 25 мес ❌]
    
    D[2027:<br/>$1K/мес на одном кластере] --> E{ROI Math}
    E --> F[Investment: $10K<br/>Payback: 14 мес ✅]
    
    style A fill:#fff3e0
    style D fill:#c8e6c9
    style C fill:#ffcdd2
    style F fill:#c8e6c9
```

**Discipline > excitement.** Хорошая архитектура нужна, но **в правильное время**.

---

## 4 Ключевых Урока

<div class="columns">

<div>

### 1️⃣ ROI Discipline
Не каждая оптимизация стоит реализации сейчас.
Define breakeven, wait for natural growth.

### 2️⃣ N Independent CRDs > Single Cluster
Relabel **до** sharding = no blind spots.
Architectural choice > zone-aware hashing.

</div>

<div>

### 3️⃣ Blind Spot Pattern
Common pitfall в sharded systems.
Где принимается решение — критично.

### 4️⃣ Compression Hides Real Cost
gzip уменьшает on-wire 5-10×.
AWS bills compressed bytes, not raw.

</div>

</div>

> 🎯 **Takeaway:** "Good architecture + good timing = ROI"

---

## Что Делаем СЕЙЧАС Вместо

```mermaid
graph LR
    Monthly[Monthly cross-AZ measure] --> Compare{Crosses $1K?}
    Compare -->|No| LowROI[Cardinality reduction<br/>3-month payback ✅]
    Compare -->|Yes| Activate[Activate scraper-locality<br/>14-month payback ✅]
    
    LowROI --> Repeat[Quarterly re-measure]
    Repeat --> Monthly
    
    style LowROI fill:#c8e6c9
    style Activate fill:#fff3e0
```

**Quarterly:** Apr 1, Jul 1, Oct 1, Jan 1 — re-baseline cross-AZ scrape.
**Trigger:** Any cluster > $1K/мес → activate.

---

## Спасибо! · Q&A

<div class="big-number">?</div>

**Dmitrii Rassvetalov**
📧 vstahanov@gmail.com
🌐 github.com/rassvetalov-d
💼 linkedin.com/in/dmitriy-rassvetalov-92297458

**Полные материалы:**
- 📄 Design doc: `case-studies/prometheus-scraper-locality.md`
- 🛠️ Production code: `github.com/Playrix/itprod-docker`
- 🎤 Companion talk: "Victoria Metrics Multi-AZ Architecture"

> "Optimize HIGH-ROI first. Wait for the trigger to flip."
