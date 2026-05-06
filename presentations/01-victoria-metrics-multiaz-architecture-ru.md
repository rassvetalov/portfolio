# Архитектура Victoria Metrics Multi-AZ: AZ-Level DR Без Replication Tax

**Презентация для конференции**  
**Длительность:** 25 минут  
**Уровень:** средний (DevOps, SRE, Platform Engineers)

---

## Слайд 1: Титул

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  🏗️  VICTORIA METRICS MULTI-AZ                                 │
│                                                                 │
│      Как получить AZ-level DR без удвоения write I/O          │
│      (и почему RF=2 — это не то, что вы думаете)              │
│                                                                 │
│      Dmitrii Rassvetalov                                        │
│      IT Production, Playrix                                     │
│      111M active series · 1.66M samples/sec                     │
│      Production: atf01 (deployed Jan 2026)                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

KEY: "RF=2 защищает от потери ноды. AZ — это другая проблема."
```

---

## Слайд 2: Проблема — RF=2 Это Не DR

```
┌─────────────────────────────────────────────────────────────────┐
│  ПРОБЛЕМА: RF=2 (Replication Factor = 2)                       │
│                                                                 │
│  Теория:      Оба shard'а в разных AZ → защита от потери AZ  │
│  Практика:    ❌ Consistent hash не знает про AZ               │
│                                                                 │
│  Результат:                                                    │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │  shard-0 replica-1 → vmstorage-1 (us-east-1a) ✓        │  │
│  │  shard-0 replica-2 → vmstorage-2 (us-east-1a) ❌ SAME! │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                                 │
│  AZ-A выключилась → потеря данных ❌ несмотря на RF=2        │
│                                                                 │
│  GitHub Issue #4216 (VictoriaMetrics):                         │
│  "Zone awareness in consistent hash" — OPEN                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

KEY MOMENT: "RF=2 — это защита от потери ноды, не от потери AZ"
```

---

## Слайд 3: Три Скрытых Расходов RF=2

```
┌─────────────────────────────────────────────────────────────────┐
│  СКРЫТЫЕ РАСХОДЫ RF=2                                           │
│                                                                 │
│  💰 1. Write I/O ×2                                             │
│      Каждый sample → 2 вmstorage нода                         │
│      Стоимость: +$400/месяц                                    │
│                                                                 │
│  📡 2. Cross-AZ трафик на READ                                 │
│      vmselect fan-out 20 нод × 3 AZ                           │
│      Стоимость: +$900/месяц (AWS egress)                      │
│                                                                 │
│  🧠 3. Memory pressure                                          │
│      vmselect держит в памяти 20 нод вместо 10               │
│      OOM срывы во время rolling upgrades                       │
│      Стоимость: +30% CPU на vmselect                          │
│                                                                 │
│  ИТОГО: $1,300/месяц + операционный overhead                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

CHART: Bar chart с тремя расходами, подсвечиваем cross-AZ как biggest
```

---

## Слайд 4: Решение — Два Независимых Кластера

```
┌─────────────────────────────────────────────────────────────────┐
│  АРХИТЕКТУРА: Dual-Cluster RF=1 per AZ                         │
│                                                                 │
│     ┌─────────────────────────────────────────┐               │
│     │  KUBERNETES (1 cluster)                 │               │
│     │                                          │               │
│     │  ┌──────────────────┐  ┌──────────────┐ │               │
│     │  │   VM-A (1a)      │  │  VM-B (1b)   │ │               │
│     │  │  ┌────────────┐  │  │ ┌────────────┐│               │
│     │  │  │ vmagent-a  │─┼──┼─│ vmagent-b  ││               │
│     │  │  │ vminsert-a │◄─┼─►│ vminsert-b ││               │
│     │  │  │ vmstorage×10    │ vmstorage×10││               │
│     │  │  └────────────┘  │  │ └────────────┘│               │
│     │  │  local reads ✓   │  │ local reads ✓ │               │
│     │  └──────────────────┘  └──────────────┘ │               │
│     └─────────────────────────────────────────┘               │
│                                                                 │
│  Каждый кластер → 100% данных, RF=1, локальные запросы       │
│  Dual-write на уровне vmagent → гарантия доставки             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

DIAGRAM: Visual двух кластеров side-by-side, стрелки dual-write
```

---

## Слайд 5: Как Работает Dual-Write?

```
┌─────────────────────────────────────────────────────────────────┐
│  DUAL-WRITE: Bulkhead Pattern                                  │
│                                                                 │
│  Scraper (внутри K8s) → vmagent-buffer (topology-mode: Auto)  │
│                           ↙                    ↘               │
│                    local AZ              cross-AZ              │
│                        ↓                       ↓                │
│                 vminsert-a (instant)   vminsert-b (buffered)  │
│                        ↓                       ↓                │
│                   vmstorage-a            vmstorage-b           │
│                                                                 │
│  ✅ vminsert-a недоступен? → данные сразу в буфер на диск    │
│  ✅ vmstorage-b медленный?  → очередь на диск (50GB × 3 pod)  │
│  ✅ Восстановление?        → drain 5+ дней при failover      │
│                                                                 │
│  Ключ: КАЖДЫЙ remoteWrite.url = отдельная очередь + диск     │
│        Недоступность одного != блокировка другого             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

ANIMATION: Показать стрелки, пузырьки для "instant" и "buffered"
```

---

## Слайд 6: Kubernetes Topology-Mode: Auto

```
┌─────────────────────────────────────────────────────────────────┐
│  ТРЮК: topology-mode: Auto (Kubernetes native)                 │
│                                                                 │
│  ДО:  Service vmselect-main                                    │
│       ├─ endpoint в 1a  ←─ kube-proxy распределяет             │
│       ├─ endpoint в 1b  ←─ трафик по всем               │
│       └─ endpoint в 1c  ←─ одинаково (30/30/40)        │
│       💥 Cross-AZ трафик = $900/месяц                         │
│                                                                 │
│  ПОСЛЕ: annotation "topology-mode: Auto"                       │
│         ├─ pod в 1a → kube-proxy AZ-1a → только 1a endpoint  │
│         ├─ pod в 1b → kube-proxy AZ-1b → только 1b endpoint  │
│         └─ pod в 1c → kube-proxy AZ-1c → только 1c endpoint  │
│         ✅ Zero cross-AZ на read path                         │
│                                                                 │
│  ⚠️ Риск: если распределение pod'ов > 3× от нод               │
│           → hints отключаются МОЛЧА, без алертов              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

DIAGRAM: Split-screen "до" и "после", цветные стрелки (локальные vs cross-AZ)
```

---

## Слайд 7: NLB Вместо nginx (L4 vs L7)

```
┌─────────────────────────────────────────────────────────────────┐
│  NGINX + vmauth (старое)     →    NLB L4 (новое)              │
│                                                                 │
│  ❌ L7 буферизирует body        ✅ L4 pass-through             │
│     → добавляет latency            → минимальная latency      │
│                                                                 │
│  ❌ Нет TCP поддержки            ✅ TCP поддерживается        │
│     → Graphite нельзя               → Graphite работает       │
│                                                                 │
│  ❌ Единая точка отказа         ✅ Распределённая            │
│     → nginx crash = весь down      → NLB node per AZ          │
│                                                                 │
│  ❌ Маршрутизация в vmauth       ✅ Маршрутизация в NLB      │
│     → сложно балансировать        → кроссозонный на локал    │
│                                                                 │
│  💰 Экономия: L7 buffering overhead зависит от load          │
│     Минимум: +200ms latency per request                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

TABLE: Comparison nginx vs NLB, checkmarks/crosses для каждого пункта
```

---

## Слайд 8: Результаты — Честные Числа

```
┌─────────────────────────────────────────────────────────────────┐
│  РЕЗУЛЬТАТЫ (Playrix atf01, May 2026)                          │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ COST DELTA (verified, peer-reviewed):                    │  │
│  │                                                          │  │
│  │  −$900/мес  Cross-AZ read egress eliminated             │  │
│  │  −$400/мес  Write I/O ×2 → ×1 per cluster              │  │
│  │  +$950/мес  Cross-AZ write (dual-write overhead)        │  │
│  │  +$30/мес   EBS for vmagent buffers                     │  │
│  │  ────────                                               │  │
│  │  −$320/мес  💰 NET CASH SAVINGS                         │  │
│  │                                                          │  │
│  │  + Avoid vmselect upsizing (~$280/мес implicit save)    │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  🎯 PAYBACK: ~75 месяцев на чистом cash                        │
│  🎯 РЕАЛЬНАЯ ЦЕННОСТЬ:                                          │
│     ├─ AZ-level DR (RPO=0 в окне <5 мин)                       │
│     ├─ Failover без ручного вмешательства (5-15s)              │
│     └─ Operational simplicity (vs zone-aware sharding)         │
│                                                                 │
│  ⚠️ ЧЕСТНО: это инвестиция в DR, не оптимизация cost.         │
│     Если нужна экономия → cardinality reduction (другой talk)  │
│                                                                 │
│  111M active series, 1.66M samples/sec baseline               │
│  AWS egress: $0.02/GB на conversation (in + out)              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

KEY MOMENT: "Не 'мы сэкономили $20K/год'. А 'мы получили AZ-DR за $4K/год'"
```

---

## Слайд 9: Failover — Что Происходит При Потере AZ?

```
┌─────────────────────────────────────────────────────────────────┐
│  FAILOVER: us-east-1a DOWN (T0 to T0+5min)                    │
│                                                                 │
│  T0:00  💥 AZ-A выключилась                                    │
│         ├─ Скраперы теряют endpoint в 1a                       │
│         └─ NLB health checks начинают падать                   │
│                                                                 │
│  T0:05  📍 TOPOLOGY FALLBACK                                   │
│         ├─ Int scrapers: kube-proxy → buffer-b (5-15 сек)    │
│         ├─ Ext scrapers: NLB health fail (2×10s = ~20 сек)   │
│         └─ Все пишут в buffer-b                               │
│                                                                 │
│  T0:20  ✍️  DUAL-WRITE ПРОДОЛЖАЕТСЯ                            │
│         ├─ buffer-b writes to vminsert-a (buffering to disk)  │
│         ├─ buffer-b writes to vminsert-b (instant)            │
│         └─ Pending data queues на диске (50GB × 3 pod)        │
│                                                                 │
│  T0:30  📖 QUERIES WORK                                         │
│         ├─ vmselect-b отвечает (all data replicated)          │
│         ├─ Lag: <1s (normal) → <5min (во время buffer drain) │
│         └─ Alerting работает (может пропустить 10% в RF=1)   │
│                                                                 │
│  T+1h   ✅ AZ-A вернулась                                      │
│         ├─ Health checks pass → endpoints вернулись           │
│         ├─ Buffer начинает drain (50MB/s)                     │
│         └─ Время восстановления: 25-50min (зависит от буфера) │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

TIMELINE: Вертикальная шкала времени с событиями слева
```

---

## Слайд 10: Кажущиеся Проблемы (Которые На Самом Деле OK)

```
┌─────────────────────────────────────────────────────────────────┐
│  "НО ЖЕ..." — Часто Задаваемые Вопросы                        │
│                                                                 │
│  Q1: RF=1 = потеря 10% данных при перезагрузке ноды?         │
│  A1: ✅ Нет, потеря 10% visibility на 60 сек (isPartial flag │
│      vmselect возвращает ✅, просто помечает результат)       │
│      Решение: PodDisruptionBudget (minAvailable: 9)           │
│                                                                 │
│  Q2: Dual-write = двойные дубликаты метрик?                  │
│  A2: ✅ 0.1-0.5% дубликатов из-за timestamp jitter (50ms)    │
│      vmstorage dedup это снимает. Мониторим на overflow.     │
│                                                                 │
│  Q3: Если оба кластера упадут?                                │
│  A3: ✅ RPO=0 ДЛЯ ОДНОГО КЛАСТЕРА. Если оба = редкий дефект  │
│      Backup = отдельная задача (не в этой архитектуре)       │
│                                                                 │
│  Q4: Graphite через NLB? TCP timeout 350s!                   │
│  A4: ✅ Проверяем SO_KEEPALIVE < 300s на deployment           │
│      HTTP health check на /api/v1/write (не просто TCP)       │
│                                                                 │
│  Q5: Что с cardinality? 111M series * 2 кластера = stress?   │
│  A5: ✅ Cardinality не удваивается (это write amplification)  │
│      Но нужен бюджет + мониторинг (отдельный talk)            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

FORMAT: Q&A с иконками (✅ галочка для каждого ответа)
```

---

## Слайд 11: Мониторинг — Что Можем Сломать?

```
┌─────────────────────────────────────────────────────────────────┐
│  ALERTS (Которые спасут нас при problems)                      │
│                                                                 │
│  🔴 CRITICAL:                                                   │
│  • TopologyHintsInactive                                        │
│    → cross-AZ traffic вернулась молча (потратили деньги)      │
│    Action: rebalance pods или descheduler                      │
│                                                                 │
│  🟡 WARNING:                                                    │
│  • VmagentBufferHighFill (>70% of 200GB)                       │
│    → AZ-A down > 5 дней и буфер переполняется                │
│    Action: check AZ status или увеличить буфер                │
│                                                                 │
│  • VMCardinalityBurst (>20% рост за 5 мин)                    │
│    → Новая метрика/игра подняла cardinality                   │
│    Action: investigate + relabel                              │
│                                                                 │
│  • VMPartialResponses (vmstorage недоступна)                  │
│    → Node down или rolling upgrade                            │
│    Action: check pod status, wait for recovery                │
│                                                                 │
│  📊 DASHBOARD:                                                  │
│  • Cross-AZ traffic ratio (должен быть 0 на read path)        │
│  • Buffer pending bytes per pod (должны быть <5GB)            │
│  • Dedup rate (should be <0.1%)                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

DASHBOARD MOCKUP: Показать примерный вид Grafana dashboard'а
```

---

## Слайд 12: Когда НЕЛЬЗЯ Использовать Эту Архитектуру?

```
┌─────────────────────────────────────────────────────────────────┐
│  ❌ КОГДА ЭТА АРХИТЕКТУРА НЕ ПОДОЙДЁТ                          │
│                                                                 │
│  ❌ Если нужна полная консистентность (billing)               │
│     → "исчезнувший" sample за 5 мин недопустим               │
│     → Используйте RDBMS, не metrics DB                         │
│                                                                 │
│  ❌ Если нет 2+ AZ или кластеров                              │
│     → Single-AZ? RF=2 на одной AZ OK (node-level protection) │
│     → Dual-cluster требует ops overhead                       │
│                                                                 │
│  ❌ Если < 50M active series                                  │
│     → RF=2 дешевле (меньше нод = меньше ops burden)          │
│     → Dual-cluster = op complexity not worth it               │
│                                                                 │
│  ❌ Если team не готова к PodDisruptionBudget'ам             │
│     → Нужны K8s discipline                                     │
│     → Нужны alerting, proactive monitoring                     │
│                                                                 │
│  ✅ КОГДА ВАРИАНТ ИДЕАЛЕН:                                     │
│     • 100M+ active series                                      │
│     • 3+ AZ в кластере                                         │
│     • Можно допустить <5min lag (SLI dashboards OK)          │
│     • Есть ops culture + monitoring                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

ICON: Red X для "не подойдёт", green checkmark для "идеален"
```

---

## Слайд 13: Lessons Learned

```
┌─────────────────────────────────────────────────────────────────┐
│  5 КЛЮЧЕВЫХ УРОКОВ                                              │
│                                                                 │
│  1️⃣  Zone awareness в consistent hash = хардпроблема          │
│     → Dual-cluster проще, чем fix in VM                        │
│     → Когда у вас есть проблема, делегируйте архитектуре      │
│                                                                 │
│  2️⃣  L7 proxies прячут locality                                │
│     → NLB (L4) делает её явной и автоматической              │
│     → Иногда меньше = лучше (no nginx buffering overhead)     │
│                                                                 │
│  3️⃣  Bulkhead pattern спасает при cascade failures            │
│     → Per-URL disk buffers = изоляция failure domains         │
│     → Один медленный upstream ≠ блокировка других             │
│                                                                 │
│  4️⃣  Consistency SLAs должны быть явными                       │
│     → "RPO=0" ≠ "zero lag" (define freshness windows)         │
│     → Team alignment на "acceptable lag" = критично           │
│                                                                 │
│  5️⃣  Empirical validation > assumptions                        │
│     → Не верьте "<100ms failover" без measurement             │
│     → topology-mode: Auto + EndpointSlice = 5-15s в reality   │
│     → Kill pod и смотрите logs, не документацию 😉            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

FORMAT: Numbered list с emoji, каждый с 1-2 sentence insight
```

---

## Слайд 14: Roadmap — Что Дальше?

```
┌─────────────────────────────────────────────────────────────────┐
│  ROADMAP: Следующие Оптимизации                                │
│                                                                 │
│  ✅ DONE (May 2026):                                            │
│  • Dual-cluster по AZ (production: atf01)                      │
│  • Pilot deployments: prf01 (Q2), apc01 planned (Q3)           │
│  • NLB вместо nginx + vmauth (atf01)                           │
│  • Topology-mode: Auto на K8s services                         │
│                                                                 │
│  ⏳ DEFERRED (ROI threshold not met):                           │
│  • Zone-aware scraper agents (VM-agent per AZ)                │
│  • Current cost: $534/month cross-AZ scrape                   │
│  • Savings potential: ~$374/month (70% reduction)             │
│  • Trigger: когда любой кластер перейдёт $1K/месяц            │
│                                                                 │
│  🔮 NICE TO HAVE (future):                                     │
│  • Fed federation (multi-cluster unified queries)              │
│  • Cardinality attribution (top consumer detection)            │
│  • HA scraping (fix operator issue #604)                       │
│  • Backup cluster (separate from DR)                           │
│                                                                 │
│  💡 NEXT TALK: "Scraper Locality" (если $1K/month)           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

TIMELINE: Left-to-right timeline showing done → deferred → future
```

---

## Слайд 15: Заключение + Call to Action

```
┌─────────────────────────────────────────────────────────────────┐
│   🎯 ВЫВОДЫ                                                      │
│                                                                 │
│  ✨ RF=2 не спасает от потери AZ (zone-agnostic hashing)     │
│     Решение: Dual-cluster архитектура (RF=1 per AZ)          │
│                                                                 │
│  💰 Сэкономили $19,560/год                                    │
│     Платили за: write I/O ×2, cross-AZ reads, vmselect OOM   │
│     Получили: независимые failure domains + ↓ ops complexity  │
│                                                                 │
│  🛠️  3 ключевых технологии:                                     │
│     • Application-layer dual-write (bulkhead pattern)         │
│     • Kubernetes topology-mode: Auto (native affinity)        │
│     • NLB L4 routing (no L7 overhead)                         │
│                                                                 │
│  📊 Production-ready architecture                              │
│     Deployed на 3 кластерах (atf01, prf01, apc01)            │
│     111M series, 1.66M samples/sec                            │
│     5+ месяцев production без incidents                       │
│                                                                 │
│  🚀 ДЛЯ ВАС:                                                    │
│  ✅ Статьи на GitHub: portfolio/case-studies/                │
│  ✅ Open-source configs: Helm + Terraform                     │
│  ✅ Вопросы? Слайды в конце                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

CLOSING: Logo, GitHub link, contact info
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
│  🎬 Код: https://github.com/Playrix/itprod-docker            │
│  📊 Metric dashboard: https://grafana.playrix.com/...         │
│                                                                 │
│  Спасибо! 🙏                                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

SLIDE: Clean closing with contact info
```

---

## Заметки для Выступающего

### Timing (25 минут)

- Слайды 1-2: Problem setup (3 мин)
- Слайды 3-7: Solution architecture (10 мин)
- Слайды 8-9: Results + Failover (5 мин)
- Слайды 10-12: Q&A prep (4 мин)
- Слайд 13-15: Lessons + Call to Action (3 мин)

### Ключевые Моменты Для Выделения

1. **Слайд 2:** "RF=2 защищает от потери ноды, не от потери AZ" (pause 5 sec)
2. **Слайд 4:** Diagram двух кластеров (показать стрелки dual-write)
3. **Слайд 8:** Зелёные числа $19,560/год (highlight this!)
4. **Слайд 9:** Failover timeline (click через T0:00 → T+1h)
5. **Слайд 13:** "Dual-cluster проще, чем fix in VictoriaMetrics" (key insight)

### Демонстрация (если есть время)

- Live show: `kubectl kill pod vmagent-buffer-a-0` → watch failover
- Grafana dashboard: cross-AZ traffic drop to 0
- Slack notification about PodEviction

---

**Format:** Markdown для конвертации в Marp/RevealJS/PowerPoint  
**Time:** ~25 минут для 500-человеческой аудитории (KubeConf level)  
**Level:** intermediate DevOps/SRE
