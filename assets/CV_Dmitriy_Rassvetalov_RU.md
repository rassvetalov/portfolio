# Дмитрий Рассветалов

**Platform / DevOps Lead · SRE**  
AWS · Kubernetes (EKS) · Terraform · Observability · FinOps automation  
Лимассол, Кипр · +357 99043151 · vstahanov@gmail.com  
LinkedIn: https://linkedin.com/in/dmitriy-rassvetalov-92297458 · GitHub: https://github.com/rassvetalov

> Public / NDA-safe note: документ предназначен для публичного репозитория. Не содержит внутренних доменов/ID/названий команд/сервисов и точной топологии.

---

## Профиль
DevOps/Platform инженер с опытом **20+ лет** (эксплуатация, сети, инфраструктура, облака). Последние годы — фокус на **AWS**, **Kubernetes (EKS)**, **IaC (Terraform/Terragrunt)**, **CI/CD**, **observability**, надежность и автоматизацию платформы. Есть опыт управления командой и выстраивания процессов: планирование/приоритизация, incident management, взаимодействие с разработкой.

**Scope:** платформа из **30+ EKS кластеров** (prod/test/stage) для сервисов и внутренних продуктов.

---

## Ключевые достижения (по значимости для работодателя)
- **EKS platform @ scale (30+ кластеров):** owner сетевых и смежных подсистем (service exposure, DNS, ingress/egress, интеграции наблюдаемости) для prod/test/stage окружений.
- **Cloudflare Zero Trust для публикации сервисов:** спроектировал и внедрил модель доступа (applications/policies, DNS-интеграция). Время выдачи безопасного доступа к сервисам сократилось с **1–2 рабочих дней до 10–15 минут** (для стандартного onboarding), доля ручных операций в настройках доступа снизилась примерно на **~30%**.
- **Self-service provisioning (GitHub + Atlantis):** вместе с командой выстроил декларативный provisioning, где разработчики описывают ресурсы в репозитории, а Atlantis применяет изменения. Мой вклад — Terraform-модули для **AWS** и **Cloudflare Zero Trust**. Типовые инфраструктурные запросы закрываются за **~30–60 минут** вместо **1–2 дней**, обращения к DevOps по рутинному провижинингу снизились на **~30–40%**.
- **FinOps automation для perf-окружений:** реализовал систему оптимизации затрат на базе **Cloud Custodian**, запущенную в **EKS CronJobs** (daily/weekly), с отчётами в **S3** и уведомлениями в **Slack** через SQS/c7n-mailer. Safety: **dry-run**, protection tags, workflow **mark-for-op → grace period → action**. Экономия на perf-окружениях — **~20–35%/мес**, заметно меньше “забытых” ресурсов.
- **Закрытие “пробелов” провайдеров для автоматизации:**  
  - кастомный плагин для управления throughput DynamoDB GSI;  
  - webhook API на FastAPI для операций, которых нет “из коробки” (например, части операций с ElastiCache replication groups), с Prometheus metrics, validation, IRSA и region allowlist.
- **Наблюдаемость (VictoriaMetrics + Prometheus + Grafana):** централизовал сбор метрик, унифицировал алерты/дашборды, внедрил лимиты кардинальности и контроль “тяжёлых” запросов. Итог — быстрее диагностика/разбор деградаций (**~20–25%**) и меньше шума алертов (**~20–30%**).
- **Production monitoring stack (Graphite/Carbon → VictoriaMetrics):** спроектировал и задеплоил продовый стек метрик: **6-node go-carbon** (consistent hashing) с **~60TB storage**, CarbonAPI, Grafana HA (**3 replicas**) с LDAP и unified alerting, интеграция современной метрик-системы с legacy Graphite.
- **Централизованное логирование @ scale:** реализовал logs-aggregator на Fluentd (50+ типов логов, 700+ routing rules), multi-AZ деплой с HPA (**1–30 реплик**) и file buffering (**~5GB/worker**), интеграция с AWS OpenSearch Service и авто-масштабирование.
- **Кастомные Prometheus exporters (Go/Python) под “метрические дыры” AWS:** exporters для DynamoDB warm capacity / Kinesis shards / Service Quotas; ElastiCache baseline bandwidth/capabilities; OSIS pipelines (TTL cache + rate limiting).
- **Terraform module library (production-ready):** библиотека модулей для account/networking/databases/app resources/endpoint monitoring (NDA-safe summary).
- **Nomad → EKS migration (в составе команды):** зона ответственности — сетевые и смежные подсистемы кластера; помогал снижать риски миграции для команд разработки.
- **Open-source вклад:** upstream PR в **aws-cost-exporter** — https://github.com/electrolux-oss/aws-cost-exporter/pull/50 — улучшил экспорт/фильтрацию cost-метрик для дашбордов/алертинга; подготовка отчётности ускорилась с **~1–2 часов до 15–30 минут**.
- **Automation/tooling:** 1000+ утилит/скриптов для AWS/EKS, операций с БД, мониторинга, DR/backup и провижининга (Packer/Ansible/SaltStack).

---

## Опыт работы

### Playrix Entertainment, LLC — Лимассол, Кипр
**Senior DevOps Engineer** · Окт 2022 — н.в.
- Owned networking and adjacent subsystems для EKS-платформы из **30+ кластеров** (prod/test/stage): service exposure, DNS, ingress/egress, интеграции наблюдаемости.
- **Cloudflare Zero Trust:** дизайн и внедрение публикации сервисов и безопасного доступа (standards/rollout), снижение времени выдачи доступа до **10–15 минут** (стандартный onboarding).
- **Self-service provisioning (GitHub + Atlantis):** Terraform-модули для AWS/Cloudflare, валидации и “контракт” для разработчиков; типовой провижининг **~30–60 минут**.
- **Observability:** VictoriaMetrics/Prometheus/Grafana + интеграция с legacy метриками; стандартизация дашбордов/алертов, лимиты кардинальности, контроль тяжёлых запросов.
- **Metrics stack:** спроектировал и поддерживал продовый стек метрик Graphite/Carbon → VictoriaMetrics, включая query gateway и Grafana HA.
- **Centralized logging:** развитие pipeline логов (Fluentd/Fluent Bit/Vector → OpenSearch), автоскейлинг и устойчивость.
- **FinOps automation:** Cloud Custodian в EKS (CronJobs + S3 reports + Slack) + расширения (плагин, webhook сервис) для downscale/cleanup.
- **Nomad → EKS migration:** вклад в миграцию в составе команды; зона ответственности — сетевые и смежные подсистемы.

**IT Team Lead** · Ноя 2021 — Окт 2022
- Управлял командой **7 инженеров**: приоритизация, планирование, контроль исполнения, развитие людей.
- Внедрил ритмы планирования и прозрачной поставки (Scrum-практики), формализовал incident management и пост-инцидентные разборы.

**Senior Network Administrator** · Ноя 2020 — Ноя 2021
- Развитие гибридной корпоративной сети, сервисов аутентификации/авторизации и удаленного доступа.
- Автоматизация сетевых задач и повышение повторяемости конфигураций.

---

### ООО «НИКА» — Вологда, Россия
**Директор / Руководитель IT-аутсорсинга** · Авг 2008 — Ноя 2020
- Управлял IT-компанией (аутсорсинг и поддержка), реализовал **50+ проектов** по автоматизации и инфраструктуре.
- Выстроил эксплуатационную модель (SLA, инциденты, изменения), внедрял решения связи и сетевой безопасности.

---

## Образование
**Вологодский Государственный Технический Университет** — инженер по автоматизации · 2001

---

## Языки
Русский — родной  
Английский — свободно

