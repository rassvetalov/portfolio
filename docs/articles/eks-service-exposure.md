---
title: "EKS service exposure patterns (ingress/egress, DNS, private access)"
---

# EKS service exposure patterns (ingress/egress, DNS, private access)

## Problem

Teams need access to internal services, but exposing everything publicly is not acceptable. At scale, ad-hoc exposure becomes inconsistent and hard to audit.

## Approach (draft)

- Define tiers:
  - **private** (default): reachable only from `<cluster>` / `<corp network>` / Zero Trust
  - **restricted**: authenticated users via Zero Trust
  - **public**: only when explicitly required, with extra reviews
- DNS as part of the publishing contract (`<service>.<env>.<domain>`)
- Standard ingress/egress rules and operational runbooks

## Failure modes to address

- accidental public exposure
- misrouted DNS
- policy drift between clusters/environments

