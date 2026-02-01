---
title: "Practical alert standards: routing, ownership, runbook-first"
---

# Practical alert standards: routing, ownership, runbook-first

## Problem

Without standards, alerts are noisy, hard to route, and hard to action.

## Standard (draft)

- Every alert must answer:
  - What broke?
  - What is the impact?
  - Who owns it?
  - What is the first action?
- Separate “page” vs “ticket” alerts (severity and urgency)
- Require ownership metadata and a runbook link placeholder

## Runbook-first mindset

Treat alerts as interfaces for operators: start with a short checklist and iterate.

## TODO (expand this article)

- [ ] Define severity model (page vs ticket) and routing rules
- [ ] Add a minimal runbook template (first 3 checks)
- [ ] Add a “do/don’t” list for alert rule quality (noise control)
- [ ] Add examples of ownership metadata and annotations (placeholders only)

## Navigation

- [Articles index](index)
- [Home](../index)

