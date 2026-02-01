---
title: "Observability guardrails: cardinality control and heavy query hygiene"
---

# Observability guardrails: cardinality control and heavy query hygiene

## Problem

In multi-tenant observability, uncontrolled label cardinality and expensive queries degrade reliability for everyone.

## Guardrails (draft)

- **Cardinality control**
  - ban/transform high-cardinality labels (request IDs, user IDs, raw IPs, unbounded paths)
  - define “allowed label set” per metric family
  - educate teams with short examples and reviews
- **Heavy query hygiene**
  - safe defaults for dashboards (range, step, max points)
  - detect suspicious queries and optimize them (warn → fix → restrict if needed)
  - avoid “global” queries for routine panels

## Results (ranges)

- ~20–25% faster triage
- ~20–30% less alert noise

## TODO (expand this article)

- [ ] Add a short “cardinality anti-patterns” list (with fixes)
- [ ] Add “heavy query” checklist (range/step/max points)
- [ ] Add a minimal alert annotation template + ownership guidance
- [ ] Add operational handling: detect → optimize → restrict (if needed)

## Navigation

- [Articles index](index)
- [Home](../index)

