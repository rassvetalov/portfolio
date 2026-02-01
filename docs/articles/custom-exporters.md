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

## TODO (expand this article)

- [ ] Add a minimal exporter skeleton (Python/Go, placeholders only)
- [ ] Add caching strategy examples (TTL + stale-on-error)
- [ ] Add rate limiting and retry/backoff examples
- [ ] Add label hygiene rules to prevent cardinality issues

## Navigation

- [Articles index](index)
- [Home](../index)

