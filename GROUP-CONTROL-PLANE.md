# Vet INC Group Control Plane

## Product definition

For veterinary chains, Vet INC is a **controlled price-change implementation console**.

It is not primarily an analysis dashboard, a price-recommendation engine, or a revenue-monitoring product. A central pricing/operations team uses it to carry an already-approved pricing decision across many clinics with clear scope, exceptions, authorization, execution status, and audit history.

> **Approved change set → mapped locations → exceptions resolved → implementation → confirmation → record**

Commercial pricing authority remains with the customer. Vet INC must not be framed as autonomously selecting, approving, or changing prices.

## Primary home screen: Implementation Command Center

The default screen answers operational questions:

1. What change sets are scheduled, in progress, blocked, or complete?
2. Which clinics are ready to implement?
3. Which mappings, exceptions, or approvals are blocking rollout?
4. What was confirmed live, when, by whom, and through which system path?

### Primary navigation

- **Change sets** — the central work queue; each set has a version, owner, rationale, effective date, status, scope, and approval history.
- **Rollout** — operational view by region/location/PMS path; show ready, blocked, in progress, manually confirmed, and needs attention.
- **Exceptions** — mismatched catalogue items, location overrides, missing information, or excluded locations requiring a decision.
- **Approvals** — authorized review and version lock before any implementation begins.
- **Ledger** — immutable record of all actions, confirmations, holds, and changes to scope.

## Change-set detail layout

```text
Q1 2027 Preventive Care Update                     APPROVED · EFFECTIVE JAN 15
42 locations · 186 services · 31 exceptions · Owner: Central Pricing

[ Review rollout ] [ Resolve exceptions ] [ Begin implementation ]

Readiness: 31 ready  |  8 exception held  |  3 awaiting information

Location rollout
Location | PMS / path | Scope | Status | Last action | Owner

Exceptions requiring a decision
Service mapping / local policy / excluded site / missing information

Activity ledger
Version created → scope amended → approver signed → location confirmed
```

## UI rules

- Lead with implementation state, not revenue KPIs or portfolio analytics.
- Use one **versioned change set** as the primary object, never a loose ungrouped list of recommendations.
- The primary CTA changes by state: `Review scope` → `Resolve exceptions` → `Submit for approval` → `Begin implementation` → `Confirm rollout`.
- Show mixed PMS realities honestly. Use `mapped`, `exception held`, `awaiting information`, `ready`, `in progress`, `manually confirmed`, and `needs attention`.
- Do not use universal “Apply changes” language unless the customer/system-specific implementation path has been verified.
- Keep post-change analysis as a later, secondary review surface—not the home screen or central value proposition.

## Relationship to current clinic UI

`owner.html` remains the location-level drill-down for service review and local decision context. The group control plane sits above it and lets central users manage a rollout without opening hundreds of individual clinic queues.
