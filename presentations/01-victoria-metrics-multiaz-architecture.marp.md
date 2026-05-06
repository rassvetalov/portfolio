---
marp: true
theme: gaia
class: lead
paginate: true
backgroundColor: #fff
header: 'Victoria Metrics Multi-AZ · Playrix IT Production'
footer: 'Dmitrii Rassvetalov · KubeCon EU 2026'
style: |
  section {
    font-family: 'Inter', sans-serif;
    font-size: 28px;
  }
  section.lead h1 {
    color: #1976d2;
    font-size: 56px;
  }
  section.lead h2 {
    color: #555;
    font-size: 32px;
    font-weight: 400;
  }
  h1 { color: #1976d2; }
  h2 { color: #333; border-bottom: 3px solid #1976d2; padding-bottom: 8px; }
  table { font-size: 22px; margin: auto; }
  th { background: #1976d2; color: white; }
  tr:nth-child(even) { background: #f5f5f5; }
  code { background: #f0f0f0; padding: 2px 6px; border-radius: 4px; }
  pre { background: #263238; color: #eeffff; padding: 16px; border-radius: 8px; font-size: 20px; }
  blockquote {
    border-left: 5px solid #ff9800;
    background: #fff8e1;
    padding: 12px 20px;
    font-style: normal;
  }
  .columns { display: grid; grid-template-columns: 1fr 1fr; gap: 32px; }
  .big-number { font-size: 96px; color: #1976d2; font-weight: bold; text-align: center; }
  .savings { color: #2e7d32; font-weight: bold; }
  .cost { color: #c62828; font-weight: bold; }
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

# Victoria Metrics Multi-AZ
## AZ-Level DR без Replication Tax

**Dmitrii Rassvetalov**
IT Production · Playrix
KubeCon EU 2026

---
**В продакшене:** atf01 · 111M active series · 1.66M samples/sec

> *"RF=2 защищает от потери ноды. AZ — это другая проблема."*

---

## О чём этот доклад

<div class="columns">

<div>

### 🎯 Проблема
RF=2 удваивает write I/O,
**не давая** AZ-level DR

### 💡 Решение
Два независимых RF=1 кластера
с dual-write на vmagent layer

</div>

<div>

### 📊 Результат
- Cross-AZ read: **3 hops → 0**
- Failover: **5-15s автомат**
- RPO=0 в окне **<5 мин**
- Net cost: ~−$320/мес

### 🎓 Урок
Cost ≠ единственная метрика.
**DR + simplicity** тоже ценность.

</div>

</div>

---

## Проблема: RF=2 — это не AZ-DR

[VictoriaMetrics Issue #4216](https://github.com/VictoriaMetrics/VictoriaMetrics/issues/4216):
**Consistent hash игнорирует AZ labels** при выборе replicas.

```mermaid
graph LR
    Hash[Consistent Hash Ring] --> R1[shard-0 replica-1<br/>vmstorage-pod-1]
    Hash --> R2[shard-0 replica-2<br/>vmstorage-pod-2]
    R1 -.-> AZ_A[us-east-1a]
    R2 -.-> AZ_A
    style AZ_A fill:#ffcdd2
    style R1 fill:#fff
    style R2 fill:#fff
```

При неудачной hash-распределении **обе replicas** оказываются в одной AZ.
**AZ outage → потеря данных, несмотря на RF=2.**

---

## Скрытые расходы RF=2

<div class="columns">

<div>

### 💰 Cross-AZ read tax
vmselect fan-out на 20 нод × 3 AZ:
- Каждый query = 14 cross-AZ hops
- **~$900/мес** AWS egress

### 🧠 Memory pressure
- vmselect держит state по 20 нодам
- OOM во время compaction bursts
- Risk: upsize до r7g.4xlarge

</div>

<div>

### ⚙️ Write I/O ×2
- Каждый sample → 2 vmstorage
- **+$400/мес** на storage I/O
- Compaction load удваивается

### 🚨 Operational burden
- Manual intervention при AZ outage
- Сложный recovery procedure
- Trust в систему — пострадал

</div>

</div>

---

## Решение: Dual Independent Clusters

```mermaid
graph TB
    subgraph K8s["Kubernetes Cluster (atf01)"]
        subgraph A["VM-A (us-east-1a) · RF=1"]
            BA[vmagent-buffer-a<br/>3 pods × 50GB]
            IA[vminsert-a]
            SA[vmstorage-a × 10]
            VA[vmselect-main-a × 5]
            BA --> IA
            IA --> SA
            VA --> SA
        end
        subgraph B["VM-B (us-east-1b) · RF=1"]
            BB[vmagent-buffer-b<br/>3 pods × 50GB]
            IB[vminsert-b]
            SB[vmstorage-b × 10]
            VB[vmselect-main-b × 5]
            BB --> IB
            IB --> SB
            VB --> SB
        end
        BA -.dual-write.-> IB
        BB -.dual-write.-> IA
    end
    Grafana[Grafana pods] -->|topology-mode: Auto| VA
    Grafana -->|topology-mode: Auto| VB

    style A fill:#e3f2fd
    style B fill:#f3e5f5
```

Каждый кластер хранит **100% данных** (RF=1, dual-write на application layer)

---

## Dual-Write: Bulkhead Pattern

```mermaid
sequenceDiagram
    participant S as Scraper (1a)
    participant BA as vmagent-buffer-a
    participant IA as vminsert-a (local)
    participant IB as vminsert-b (cross-AZ)
    participant DA as Disk Buffer A
    participant DB as Disk Buffer B
    
    S->>BA: scrape sample
    par Local write (instant)
        BA->>IA: write
        IA-->>BA: 200 OK
    and Cross-AZ write
        BA->>IB: write
        Note over IB: vminsert-b unavailable
        BA->>DB: queue to disk (50GB×3pods)
    end
    Note over BA,DB: Bulkhead: per-URL queue<br/>Один медленный ≠ блокировка другого
```

**Гарантия:** недоступность одного upstream НЕ блокирует другой.

---

## Kubernetes Topology-Mode: Auto

<div class="columns">

<div>

### ❌ Без annotation
```mermaid
graph TB
    P[Pod в 1a]
    P -.->|33%| E1[Endpoint 1a]
    P -.->|33%| E2[Endpoint 1b]
    P -.->|33%| E3[Endpoint 1c]
    style E2 fill:#ffcdd2
    style E3 fill:#ffcdd2
```
67% cross-AZ → **$900/мес**

</div>

<div>

### ✅ С `topology-mode: Auto`
```mermaid
graph TB
    P[Pod в 1a]
    P -->|100%| E1[Endpoint 1a]
    P -.fallback.-> E2[Endpoint 1b]
    P -.fallback.-> E3[Endpoint 1c]
    style E1 fill:#c8e6c9
```
0% cross-AZ → **$0/мес**

</div>

</div>

> ⚠️ **Silent deactivation:** при skew >3× hints отключаются БЕЗ алертов.
> Mitigation: proactive alert при 2.5× (см. Monitoring slide)

---

## NLB вместо nginx Ingress + vmauth

| Аспект | nginx + vmauth (старое) | NLB L4 (новое) |
|---|---|---|
| Слой | L7 (HTTP) | L4 (TCP) |
| Body buffering | ⚠️ Buffers request body | ✅ Pass-through |
| Latency overhead | Variable (load-dependent) | Минимальный |
| Graphite (TCP :2003) | ❌ Не поддерживается | ✅ Native |
| AZ awareness | Нет | `cross_zone=false` |
| SPOF | Один nginx instance | NLB node per AZ |

> **Note:** vmauth теперь sidecar на vminsert pod (не в request path для internal queries)

---

## Health Check: HTTP vs TCP

```hcl
health_check {
  protocol            = "HTTP"           # ✅ Не TCP!
  path                = "/api/v1/write"
  matcher             = "204"
  interval            = 5
  unhealthy_threshold = 2                # ~10s failover
}
```

**Почему HTTP, а не TCP?**
- TCP check проходит, если порт открыт — но vminsert может быть **зависший**
- HTTP check проверяет реальный response (204 = ready to write)
- Catches hung processes, OOM, deadlocks

> 💡 **NLB TCP idle timeout** теперь **configurable** (с Sept 2024, ранее hardcoded 350s).
> Для batch Graphite clients: `tcp_idle_timeout_seconds = 600`

---

## Результаты — Честные Числа

| Component | Before (RF=2) | After | Delta |
|---|---|---|---|
| Cross-AZ read egress | ~$900/mo | ~$0 | <span class="savings">−$900</span> |
| Write I/O ×2 → ×1 per cluster | $400 | $0 | <span class="savings">−$400</span> |
| Cross-AZ write (dual-write) | — | +$950 | <span class="cost">+$950</span> |
| EBS for vmagent buffers | — | +$30 | <span class="cost">+$30</span> |
| **Net cash savings** | | | **<span class="savings">−$320/mo</span>** |

<div class="key-insight">

🎯 **Это инвестиция в DR, а не оптимизация cost.**
Если нужна экономия — cardinality reduction даёт лучший ROI ($X/мес за 3 мес).

</div>

> Earlier drafts claimed "−$1,630/mo" — это было ошибочно. Vmselect "20→10" не работает (dual-cluster = 10+10 = 20 нод итого).

---

## Failover: Empirical Timing

```mermaid
gantt
    title AZ-1a Outage Timeline
    dateFormat X
    axisFormat %s
    
    section Detection
    Packet loss begins     :0, 5
    Kubelet probes fail    :5, 10
    
    section Write Path
    EndpointSlice update   :5, 15
    kube-proxy fallback    :15, 20
    NLB health check       :10, 20
    Buffer queues for vm-a :20, 300
    
    section Read Path  
    Grafana fallback to b  :5, 15
    NLB removes 1a targets :10, 20
    
    section Recovery
    AZ-1a restores         :3600, 3610
    Health checks pass     :3610, 3620
    Buffer drains 50MB/s   :3620, 6020
```

**Empirical RTO: 5-15 секунд** (не <100ms!) · Validated on production

---

## Failover: Что Видит Grafana

| Состояние | Query freshness | Lag |
|---|---|---|
| 🟢 Normal (оба кластера) | <1s | Real-time |
| 🟡 1a down, buffer-b drains | <5min | Acceptable for SLI |
| 🟠 Buffer >180GB (rate-limited) | <10min | Degraded but available |
| 🔴 Both clusters down | N/A | Backup nedoor (не RPO=0) |

<div class="key-insight">

⚠️ **"RPO=0" ≠ "zero lag".** Define your freshness SLA explicitly.
Acceptable for SLI dashboards, NOT for billing systems.

</div>

---

## "Но как же..." — Преэмптивный FAQ

<div class="columns">

<div>

### Q1: RF=1 = потеря 10% данных?
**A:** Нет. `isPartial: true` flag + PDB (`minAvailable: 9`) предотвращает.

### Q2: Дубликаты от dual-write?
**A:** 0.1-0.5% (timestamp jitter), `vmstorage dedup` снимает.

### Q3: Если оба кластера упадут?
**A:** RPO=0 — для одной AZ. Backup = отдельная задача.

</div>

<div>

### Q4: Cardinality удваивается?
**A:** Нет — это write amplification, не cardinality.
**111M в каждом кластере**, не 222M.

### Q5: NLB 350s timeout?
**A:** Configurable с Sept 2024.
Pre-deploy: SO_KEEPALIVE < 300s.

### Q6: vmctl backfill для historical?
**A:** Phase 3 of migration.
50 MB/s rate-limited.

</div>

</div>

---

## Production Monitoring (Critical Alerts)

```yaml
- alert: TopologyHintsDeactivated      # Cross-AZ traffic вернулся МОЛЧА
  expr: kube_endpointslice_annotations{...topology_mode="Auto"}
        unless on(endpointslice) {...hints_auto="yes"}
  severity: critical

- alert: VmagentBufferHighFill         # Risk потери при переполнении
  expr: vmagent_remotewrite_pending_data_bytes / (50 * 1024^3) > 0.7
  severity: warning

- alert: VMCardinalityBurst            # Новая игра / misconfig
  expr: rate(vmagent_active_series[5m]) > 1.2 * baseline
  severity: warning

- alert: TopologyHintsInactivePreventive  # Fire BEFORE silent deactivation
  expr: pod_to_node_ratio_per_zone > 2.5
  severity: warning
```

---

## Когда НЕЛЬЗЯ применять эту архитектуру

<div class="columns">

<div>

### ❌ Не подойдёт:
- **Billing systems** — нужна полная consistency
- **Single-AZ кластеры** — нет смысла
- **<50M active series** — RF=2 проще
- **Нет K8s discipline** — PDB, alerts must

</div>

<div>

### ✅ Идеален для:
- **100M+ active series**
- **3+ AZ в кластере**
- **<5min lag acceptable** (SLI ОК)
- **Production-grade ops** (monitoring, runbooks)

</div>

</div>

> **Сегодня deployed:** atf01 (production)
> **Pilot:** prf01 (Q2 2026)
> **Planned:** apc01 (Q3 2026)

---

## 5 Ключевых Уроков

1. **Zone awareness в consistent hash = хард проблема.**
   Dual-cluster проще, чем fix in upstream.

2. **L7 proxies прячут locality.**
   NLB (L4) делает её явной и автоматической.

3. **Bulkhead pattern спасает при cascade failures.**
   Per-URL disk buffers = изоляция failure domains.

4. **Consistency SLAs должны быть явными.**
   "RPO=0" ≠ "zero lag". Define freshness windows.

5. **Empirical validation > assumptions.**
   topology-mode fallback = 5-15s, не <100ms. Validate yourself.

---

## Что Дальше — Roadmap

```mermaid
timeline
    title Victoria Metrics Architecture Evolution
    Q1 2026 : Dual-cluster atf01 (production)
            : NLB вместо nginx + vmauth
            : Topology-mode Auto
    Q2 2026 : prf01 pilot
            : Cardinality budget enforcement
    Q3 2026 : apc01 deploy
            : Backup cluster (S3 snapshots)
    Q4 2026 : Re-measure scraper-locality ROI
    2027    : Activate scraper-locality (если $1K/мес threshold)
            : Federated queries proposal
```

---

## Спасибо! · Q&A

<div class="big-number">?</div>

**Dmitrii Rassvetalov**
📧 vstahanov@gmail.com
🌐 github.com/rassvetalov-d
💼 linkedin.com/in/dmitriy-rassvetalov-92297458

**Полные материалы:**
- 📄 Case studies: `github.com/rassvetalov-d/portfolio/case-studies/`
- 🛠️ Production code: `github.com/Playrix/itprod-docker`

> "Не платите дважды за то, что не получили."
