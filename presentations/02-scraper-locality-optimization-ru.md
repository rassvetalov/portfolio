# Локализация Prometheus Scraping: Когда $534/месяц Становится Проблемой

**Презентация для конференции**  
**Длительность:** 20 минут  
**Уровень:** продвинутый (Platform Engineers, FinOps)

---

## Слайд 1: Титул

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  📊 SCRAPER LOCALITY: AZ-AWARE PROMETHEUS                       │
│                                                                 │
│      Когда cross-AZ metrics стоят денег                        │
│      И как это оптимизировать (если стоит)                    │
│                                                                 │
│      Dmitrii Rassvetalov                                        │
│      IT Production, Playrix                                     │
│      7 кластеров · $534/месяц cross-AZ baseline               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

KEY: "Не всё, что можно оптимизировать, нужно оптимизировать"
```

---

## Слайд 2: Проблема — Где Живёт Трафик Скрейпа?

```
┌─────────────────────────────────────────────────────────────────┐
│  BASELINE MEASUREMENT (May 4, 2026)                            │
│                                                                 │
│  Кластер      Scrape RX    % Cross-AZ    $ Cost/мо (corrected)│
│  ─────────────────────────────────────────────────────────────│
│  apv01        7.64 MB/s    ~67%          ~$259  ⚠️ BIGGEST  │
│  prf01        2.36 MB/s    ~67%          ~$80                │
│  atf01        2.13 MB/s    ~67%          ~$108               │
│  apc01        1.51 MB/s    ~50%          ~$37                │
│  adv01        1.44 MB/s    ~67%          ~$50                │
│  adc01        0.84 MB/s    ~50%          ~$20                │
│  sbx01        0.65 MB/s    ~67%          ~$24                │
│  ────────────────────────────────────────────────────────────│
│  ИТОГО        15.57 MB/s   ~67% avg      ~$578/месяц        │
│                                                                 │
│  Способ измерения (auditable):                                  │
│  • vm_promscrape_response_size_bytes_sum (vmagent native)     │
│  • Cross-checked: AWS Cost Explorer + VPC Flow Logs           │
│  • AWS billing: $0.02/GB на conversation (in + out)           │
│  • 7-day average (April 28 - May 4, 2026)                     │
│                                                                 │
│  ⚠️ EARLIER ESTIMATE: $534/мес (использовал $0.01/GB only).   │
│     Corrected: $578/мес (учитывает в обе стороны)             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

TABLE: Большая таблица, apv01 выделена красным
```

---

## Слайд 3: Почему Scraper Ходит в Соседнюю AZ?

```
┌─────────────────────────────────────────────────────────────────┐
│  ТЕКУЩАЯ АРХИТЕКТУРА (single vmagent fleet)                   │
│                                                                 │
│     ┌─────────────────────────────────────────────────────┐   │
│     │    Kubernetes cluster (3 AZ)                        │   │
│     │                                                      │   │
│     │  AZ-1a          AZ-1b          AZ-1c              │   │
│     │  ────────      ────────       ────────             │   │
│     │  3 pod         3 pod          3 pod               │   │
│     │                                                      │   │
│     │  targets       targets        targets             │   │
│     │  (services)    (services)     (services)          │   │
│     │    │             │              │                 │   │
│     │    └─────┬───────┴──────┬──────┘                 │   │
│     │          │              │                         │   │
│     │          ▼              ▼                         │   │
│     │     vmagent pod (случайно в 1a)                  │   │
│     │     • Scrapes targets в 1b ❌ cross-AZ           │   │
│     │     • Scrapes targets в 1c ❌ cross-AZ           │   │
│     │     • Scrapes targets в 1a ✓ local               │   │
│     │     = (33% local, 67% cross-AZ)                  │   │
│     └─────────────────────────────────────────────────────┘   │
│                                                                 │
│  kubernetes scheduler НЕ знает про AZ                         │
│  → pod может быть в любой AZ независимо от targets            │
│  → максимум 33% local, минимум 0%                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

DIAGRAM: Triangle 3 AZ, vmagent pod случайно размещен, стрелки everywhere
```

---

## Слайд 4: Классическое Решение — Blind Spot!

```
┌─────────────────────────────────────────────────────────────────┐
│  ❌ НАИВНЫЙ ПОДХОД: Per-Shard Relabel                          │
│                                                                 │
│  Если бы мы сказали: "каждый shard scrapes только свою AZ"    │
│                                                                 │
│     Cluster: 15 shards (5 per AZ × 3 AZ)                      │
│                                                                 │
│     Consistent hash: target T → shard-12                      │
│     shard-12 физически в AZ-1c                               │
│     shard-12 has relabel: keep zone=1c                       │
│                                                                 │
│     target T в AZ-1a:                                          │
│     → relabel: zone=1a (есть) vs keep zone=1c                │
│     → MATCH FAILS → drop                                       │
│     → никакой другой shard не возьмёт T                       │
│     (потому что cluster ownership = shard-12)                 │
│                                                                 │
│     РЕЗУЛЬТАТ: 💥 TARGET LOST (blind spot)                   │
│                                                                 │
│  ⚠️ Это РИСК при обычном подходе к sharding!                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

DIAGRAM: Flowchart showing hash → shard → relabel → drop (dead end)
```

---

## Слайд 5: Правильное Решение — N Independent CRD

```
┌─────────────────────────────────────────────────────────────────┐
│  ✅ ПРАВИЛЬНЫЙ ПОДХОД: N VMAgent CRD (одна на AZ)             │
│                                                                 │
│  Вместо 1 кластера × 15 shards:                               │
│  Создаём 3 независимых кластера:                              │
│                                                                 │
│     ┌─────────────────────────────────────────────────────┐   │
│     │ vmagent-zone-1a (5 shards)                          │   │
│     │ • all targets (selectAllByDefault)                  │   │
│     │ • relabel: drop zone=~"1b|1c" (BEFORE sharding)    │   │
│     │ • sharding hash(T) % 5 → один из 5 shards в 1a    │   │
│     │ → target T в 1a: relabel PASS → sharding → scrape ✓│   │
│     └─────────────────────────────────────────────────────┘   │
│                                                                 │
│     ┌─────────────────────────────────────────────────────┐   │
│     │ vmagent-zone-1b (5 shards)                          │   │
│     │ • relabel: drop zone=~"1a|1c"                       │   │
│     │ → target T в 1a: relabel DROP (before sharding)    │   │
│     │ → никогда не учитывается в cluster ownership        │   │
│     │ → другие шарды не "владеют" T                       │   │
│     └─────────────────────────────────────────────────────┘   │
│                                                                 │
│  ✨ KEY: Relabel BEFORE sharding = no blind spots            │
│          Каждая CRD = независимое пространство sharding      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

DIAGRAM: 3-column diagram showing each CRD independently
```

---

## Слайд 6: T-Shirt Sizing — Один Параметр Для Всего

```
┌─────────────────────────────────────────────────────────────────┐
│  PRESET CONFIG: cluster_size ∈ {s, m, l, xl}                 │
│                                                                 │
│         s (sandbox)    m (test, default)  l (prod)    xl (high)
│  ──────────────────────────────────────────────────────────────
│  zoned shards    1              2             5          8     │
│  catch-all       1              2             8          12    │
│  storage         10Gi           20Gi          50Gi       100Gi │
│  CPU request     50m            100m          200m       500m  │
│  Memory request  128Mi          256Mi         500Mi      1Gi   │
│                                                                 │
│  АВТОМАТИЧЕСКИЙ ВЫБОР AZ:                                      │
│  • Input nodes_subnet_names: "atf01-eks-natted-eu-central-1a" │
│  • Regex: eu-central-1a → добавляем в zones                  │
│  • Не нужно вручную писать AZ список!                         │
│                                                                 │
│  ПРИМЕР CONFIG:                                                 │
│  metrics_victoria_metrics_k8s_stack = {                        │
│    az_locality = {                                             │
│      enabled      = true                                       │
│      cluster_size = "l"  # 5 shards, 50Gi, typical prod      │
│    }                                                            │
│  }                                                              │
│                                                                 │
│  vs старый подход: 15 строк terraform по zoning 😅           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

TABLE: T-shirt sizes, highlight "l" as typical prod
```

---

## Слайд 7: Catch-All AZ (Для Случаев Без Zone Label)

```
┌─────────────────────────────────────────────────────────────────┐
│  EDGE CASE: Targets Без Zone Label                             │
│                                                                 │
│  Некоторые targets не имеют K8s metadata:                      │
│  • apiserver (EKS control plane, managed)                      │
│  • VMProbe targets (blackbox exporter, static_configs)         │
│  • Pending pods (ещё нет node assignment)                      │
│                                                                 │
│  РЕШЕНИЕ: Catch-All VMAgent                                   │
│                                                                 │
│  vmagent-zone-1a-catchall (catch-all в primary AZ):           │
│  • relabel: drop zone=~"1b|1c" (drop if zone IS other)       │
│  • "" (пусто) не матчит regex 1b|1c → PASS                   │
│  • Проходит через и scrapes                                    │
│                                                                 │
│  vmagent-zone-1b (ordinary zoned):                             │
│  • relabel: keep zone=1b                                       │
│  • "" (пусто) не матчит 1b → DROP                             │
│  • probeSelector: never-match (no VMProbe)                     │
│                                                                 │
│  ✨ BENEFIT: Single relabel rule handles all edge cases       │
│     (apiserver, probes, orphans) → 1 pod, not 4              │
│                                                                 │
│  ⚠️ RISK: Catch-all AZ down → gap в apiserver/probe metrics   │
│     Mitigation: catch-all в primary AZ (historically stable)   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

DIAGRAM: Showing zone label propagation vs catch-all fallthrough
```

---

## Слайд 8: Текущее Состояние — ROI Анализ

```
┌─────────────────────────────────────────────────────────────────┐
│  ФИНАНСОВЫЙ АНАЛИЗ: Когда Оптимизировать?                     │
│                                                                 │
│  BASELINE (May 4, 2026):                                        │
│  • Org-wide cross-AZ scrape: $534/месяц                       │
│  • Potential savings (70% reduction): ~$374/месяц             │
│  • One-time operational cost: ~$5-10K (design, rollout)       │
│                                                                 │
│  ROI CALCULATION:                                               │
│  │ Payback = $7,500 ÷ $374/месяц = 20 месяцев ❌ TOO LONG    │
│                                                                 │
│  THRESHOLD ANALYSIS:                                            │
│  │ At $1K/месяц per-cluster (4× growth):                       │
│  │ Payback = $7,500 ÷ $700 = ~11 месяцев ✅ reasonable        │
│                                                                 │
│  CURRENT STATUS: ⏸️ DEFERRED                                   │
│  ✓ Design complete & frozen                                    │
│  ✓ Ready to activate without re-design                        │
│  ✗ No cluster exceeds $1K/месяц (apv01 = $240)               │
│                                                                 │
│  RE-TRIGGER CONDITION:                                         │
│  • Quarterly measurement (апрель, июль, октябрь, январь)      │
│  • If ANY cluster: cross-AZ ≥ $1K/месяц → GO                 │
│  • Most likely: apv01 при 4× рост трафика (est. 2027)         │
│                                                                 │
│  💡 ALTERNATIVE OPTIMIZATION (higher ROI):                     │
│     Cardinality reduction + scrape interval tuning             │
│     (Separate talk)                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

CHART: Timeline showing threshold $1K/month crossover point
```

---

## Слайд 9: Активация — Когда Это Наконец Произойдёт?

```
┌─────────────────────────────────────────────────────────────────┐
│  ACTIVATION ROADMAP (когда перейдём $1K/месяц)                 │
│                                                                 │
│  PHASE 1: Re-baseline                                           │
│  • Quarterly measurement (апрель 2027?)                        │
│  • If apv01 ≥ $1K/месяц → flip trigger                        │
│                                                                 │
│  PHASE 2: Design validation                                    │
│  • Chart bump 0.35 → 0.70 (precondition)                      │
│  • Deploy to sbx01 (sandbox validation)                        │
│  • 24h soak test                                               │
│                                                                 │
│  PHASE 3: Progressive rollout                                  │
│  • Parallel vmagent (old + new N CRDs)                         │
│  • 10% traffic → N CRDs, 90% → old                            │
│  • Monitor for duplicates, targets lost, cardinality           │
│  • Gradual shift: 10 → 25 → 50 → 75 → 100%                  │
│                                                                 │
│  PHASE 4: Cleanup                                              │
│  • Delete old single vmagent release                           │
│  • Verify cross-AZ traffic dropped 70%                         │
│  • Confirm savings on AWS billing                              │
│                                                                 │
│  ⏱️  ESTIMATED TIMELINE:                                        │
│  • Design → activation: 2 weeks (parallel deployment)          │
│  • Parallel run: 1 week (safety buffer)                        │
│  • Cleanup: 1 day                                              │
│  • Total: ~1 month operational effort                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

TIMELINE: 4 phases with estimated durations
```

---

## Слайд 10: Operational Gotchas

```
┌─────────────────────────────────────────────────────────────────┐
│  ⚠️  THINGS THAT CAN GO WRONG                                   │
│                                                                 │
│  1️⃣  Operator Issue #604 (replicaCount duplicate scrapes)     │
│     • Can't run 2+ replicas per shard (creates duplicates)    │
│     • Currently accepted: 30-90s gap per week (rolling restart)│
│     • When probe-load grows: need vmagent-probes separate CRD │
│                                                                 │
│  2️⃣  Silent Cardinality Explosion                              │
│     • New game release = +50M series overnight                 │
│     • If dual-AZ localization: pay 2× for cardinality         │
│     • Need alerting: cardinality burst > 20% in 5min           │
│                                                                 │
│  3️⃣  Incomplete Scratch Configs                                │
│     • Custom scrape configs may not have node metadata         │
│     • Falls through to catch-all (single point of failure)    │
│     • Mitigation: audit all scrape configs before rollout     │
│                                                                 │
│  4️⃣  Network Policy Misconfiguration                           │
│     • If strict network policies: pods can't reach cross-AZ   │
│     • Test: kubectl exec vmagent pod → curl targets in 1b    │
│                                                                 │
│  5️⃣  CI/CD Testing Difficulty                                  │
│     • Hard to simulate multi-AZ locally                        │
│     • Must test on staging with real 3-AZ cluster            │
│     • Expect 2-3 weeks staging validation                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

ICONS: Warning sign, red X for each gotcha
```

---

## Слайд 11: Comparison — Trade-Off Honest

```
┌─────────────────────────────────────────────────────────────────┐
│  ARCHITECTURE COMPARISON (honest trade-offs)                   │
│                                                                 │
│                    SINGLE AGENT      N AGENTS (AZ-AWARE)       │
│  ─────────────────────────────────────────────────────────────│
│  Deployment        1 StatefulSet     N CRD (3 для 3 AZ)        │
│  Operational       Simple             +Complexity (sizing,DRY) │
│  Cross-AZ cost     $578/мес           ~$170/мес (70% save)     │
│  Pod scheduling    Random across AZ   nodeAffinity per AZ      │
│                                                                 │
│  Failover на pod   30-60s pod restart 30-60s pod restart       │
│                    (другой shard)     (внутри той же AZ)       │
│                                                                 │
│  Failover на AZ    Other AZ продолжат AZ-pod ↔ targets-в-той   │
│                    scrape (cross-AZ)  AZ STOP до восстановления│
│                                                                 │
│  Resilience        Higher (zone loss  Lower (catch-all AZ      │
│                    redistributes)      = SPOF for apiserver)   │
│                                                                 │
│  ROI threshold     n/a                $1K/мес per cluster      │
│  Chart deps        chart 0.35+        chart 0.70+ + op v0.61+  │
│                                                                 │
│  ВЕРДИКТ:                                                       │
│  ✓ Deploy today: single agent — резильентнее + ROI not там     │
│  ⏳ В 2027 (когда $1K/мес): N agents — экономия выгоднее       │
│                                                                 │
│  TRADE-OFF: Cost savings vs. AZ-failure resilience              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

KEY: "Single agent более resilient к AZ failure. N agents дешевле."
```

---

## Слайд 12: Мониторинг — Что Отслеживаем?

```
┌─────────────────────────────────────────────────────────────────┐
│  METRICS & ALERTS (для текущего single-agent режима)           │
│                                                                 │
│  📊 BASELINE TRACKING:                                          │
│  • Quarterly cross-AZ scrape cost measurement                  │
│  • Alert if trend: >$1K/месяц for any cluster                 │
│  • Dashboard: scrape RX per AZ (AWS billing attribution)      │
│                                                                 │
│  🔍 READINESS SIGNALS (когда готовы к активации):             │
│  • Chart version ≥ 0.70 deployed                               │
│  • Operator fix #604 (if available)                            │
│  • Cardinality stable (no recent explosions)                   │
│  • Team trained on multi-CRD operations                        │
│                                                                 │
│  🎯 ACTIVATION CHECKS (когда переходим на N agents):           │
│  • Zero duplicates detected                                     │
│  • All targets still scraped (no blind spots)                  │
│  • Cross-AZ traffic <5% (was 67%)                             │
│  • Pod distribution balanced per AZ                            │
│                                                                 │
│  ⚠️ POST-ACTIVATION (в production):                             │
│  • VMCardinalityBurst (>20% in 5min)                           │
│  • Operator #604 failures (replicaCount > 1 duplicates)       │
│  • Catch-all AZ down (apiserver/probe gap)                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

DASHBOARD MOCK: Show cross-AZ cost tracking
```

---

## Слайд 13: Почему СЕЙЧАС Не Делаем?

```
┌─────────────────────────────────────────────────────────────────┐
│  "ПОЧЕМУ МЫ ДОЖИДАЕМСЯ, ЕСЛИ МОЖЕМ ДЕЛАТЬ СЕЙЧАС?"           │
│                                                                 │
│  Хороший вопрос! Но:                                           │
│                                                                 │
│  $374/месяц savings = $4,488/год                              │
│  $10,000 operational investment (design, staging, rollout)    │
│  Payback = 27 месяцев (не стоит)                              │
│                                                                 │
│  ✅ ВМЕСТО: Делаем Cardinality Reduction                       │
│  • Drop unnecessary labels (reduce 20% series → $100/мо save) │
│  • Increase scrape interval (15s → 30s → $50/мо save)        │
│  • Both ROI: 3-6 месяцев ✓                                    │
│                                                                 │
│  💡 LESSON: "Оптимизируйте HIGH-ROI первыми"                 │
│  • Cardinality > scraper locality (for now)                   │
│  • В 2027 при $1K/месяц → landscape меняется → локальность  │
│                                                                 │
│  👨‍💼 BUSINESS DECISION:                                        │
│  ✓ Design frozen (zero incremental cost to maintain)          │
│  ✓ Trigger defined ($1K/месяц)                               │
│  ✓ Team trained (knows how to activate)                       │
│  ✓ Wait for 4× cardinality growth → natural ROI rise         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

TEXT: Big question, then answer with chart
```

---

## Слайд 14: Lessons Learned

```
┌─────────────────────────────────────────────────────────────────┐
│  4 КЛЮЧЕВЫХ УРОКОВ                                              │
│                                                                 │
│  1️⃣  ROI Threshold Discipline                                   │
│     • Not every optimization is worth doing immediately        │
│     • Define breakeven point ($1K/месяц per cluster)          │
│     • Wait for natural growth or revisit quarterly            │
│                                                                 │
│  2️⃣  N Independent CRDs > Single Cluster with Relabel         │
│     • Relabel BEFORE sharding avoids blind spots              │
│     • Each CRD = independent sharding space (safe!)            │
│     • Scales better than "add zone awareness to hash"          │
│                                                                 │
│  3️⃣  Blind Spot Problem in Distributed Systems                 │
│     • Naive relabel + cluster ownership = data loss           │
│     • Common pitfall in many monitoring stacks                 │
│     • Think carefully about where decisions are made           │
│                                                                 │
│  4️⃣  Gzip Compression Hides True egress Costs                  │
│     • container_network_* counts on-wire (compressed) bytes   │
│     • AWS billing = compressed, not decompressed              │
│     • Actual savings opportunity much smaller than it looks   │
│                                                                 │
│  🎯 TAKEAWAY: "Good architecture + good timing = ROI"         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

FORMAT: Numbered lessons with icons
```

---

## Слайд 15: Заключение + Next Steps

```
┌─────────────────────────────────────────────────────────────────┐
│  🎯 ЗАКЛЮЧЕНИЕ                                                   │
│                                                                 │
│  ТЕКУЩЕЕ СОСТОЯНИЕ (May 2026):                                 │
│  • Baseline: $534/месяц cross-AZ scrape (7 кластеров)         │
│  • Design: frozen, ready to activate                          │
│  • Decision: wait for $1K/месяц ROI threshold                 │
│                                                                 │
│  ЧТО МЫ ДЕЛАЕМ ВМЕСТО:                                         │
│  • Cardinality reduction (bigger ROI, faster payback)         │
│  • Scrape interval tuning (low risk, high impact)             │
│                                                                 │
│  КОГДА ПЕРЕХОДИМ:                                              │
│  • Quarterly re-measurement (quarterly reviews)               │
│  • Trigger: any cluster > $1K/месяц baseline                 │
│  • Estimated: 2027 (apv01 при 4× growth)                    │
│                                                                 │
│  🚀 ДЛЯ ВАС:                                                    │
│  ✅ Design docs: case-studies/prometheus-scraper-locality.md │
│  ✅ ROI calc template: make it for your org                    │
│  ✅ Baseline measure: quarterly check-in                       │
│  ✅ Questions? Last slide!                                     │
│                                                                 │
│  💪 REMEMBER:                                                   │
│  "Optimize HIGH-ROI first. Wait for natural growth to hit ROI threshold."
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

CLOSING: Recap + call to action
```

---

## Слайд 16: Q&A

```
┌─────────────────────────────────────────────────────────────────┐
│  ? QUESTIONS                                                    │
│                                                                 │
│  Dmitrii Rassvetalov                                            │
│  dmitrii@playrix.com / GitHub: rassvetalov-d                  │
│                                                                 │
│  Материалы:                                                    │
│  📄 Полные статьи: ~/git/portfolio/case-studies/              │
│  📊 Calc spreadsheet: https://playrix-infra.notion.so/...    │
│  📈 Baseline data: CloudWatch dashboards (internal)            │
│                                                                 │
│  Спасибо! 🙏                                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

SLIDE: Clean closing
```

---

## Заметки для Выступающего

### Timing (20 минут)

- Слайды 1-3: Problem setup (4 мин)
- Слайды 4-7: Solution architecture (8 мин)
- Слайд 8-9: ROI analysis + activation (4 мин)
- Слайды 10-13: Gotchas + why wait (3 мин)
- Слайд 14-15: Lessons + conclusion (1 мин)

### Emphasis Points

1. **Слайд 2:** "$534/месяц cross-AZ" (highlight orange)
2. **Слайд 4:** "Blind spot!" (pause 3 sec)
3. **Слайд 8:** "$1K/месяц threshold" (this is THE key decision)
4. **Слайд 13:** "Why we wait" (explain vs other optimizations)

### Live Demo (if time)

- Show: `kubectl explain vmagent` (operator CRD)
- Show: Grafana dashboard with RX bytes per AZ
- Optional: live kubectl command to show pod distribution

### Audience Interaction

- Слайд 8: Poll — "Who has >$1K/месяц cross-AZ scrape?"
- Слайд 13: "Hands up if you disagree with waiting?" (opens discussion)

---

**Format:** Markdown для Marp/RevealJS/PowerPoint  
**Time:** ~20 минут для 200-300 человеческой аудитории (FinOps/Platform track)  
**Level:** advanced DevOps/FinOps (requires understanding of networking costs)
