---
title: "Custom Prometheus exporters: caching, rate limiting, retries (patterns)"
---

# Custom Prometheus exporters: caching, rate limiting, retries (patterns)

## When you need custom exporters

You build an exporter when:

- the platform does not expose the signal you need (or not in the right form)
- CloudWatch metrics exist but are too costly/slow to query at scale
- you need metadata-style metrics (capabilities, limits, inventory) for alerting/routing

## Patterns (draft)

- **Cache with TTL** for inventory and expensive APIs
- **Rate limiting** (token bucket) for AWS APIs
- **Retry/backoff** for transient failures and throttling
- **Fail-soft**: serve last-known-good data when safe
- **Explicit labels** and guardrails to avoid cardinality explosions

## NDA-safe principle

Share patterns and code skeletons with `<placeholders>`, never internal resource names/IDs.

