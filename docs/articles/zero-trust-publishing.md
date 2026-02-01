---
title: "Zero Trust service publishing (Cloudflare Zero Trust)"
---

# Zero Trust service publishing (Cloudflare Zero Trust)

## Problem

Secure access to internal services traditionally requires manual provisioning and slow coordination across teams.

## Approach (draft)

- Keep services private by default
- Authenticate via `<IdP>`
- Enforce access with Zero Trust applications/policies
- Integrate DNS into the publishing workflow

## Result (ranges)

- Access lead time reduced from 1–2 business days to 1–2 hours
- Manual operations reduced by ~30%

## TODO (expand this article)

- [ ] Add threat model summary (private-by-default, least privilege)
- [ ] Add onboarding flow for a new `<service>` (checklist)
- [ ] Add failure modes and runbook (IdP/policy/DNS/connector/service)
- [ ] Add trade-offs vs alternatives (still NDA-safe)

## Navigation

- [Articles index](index)
- [Home](../index)

