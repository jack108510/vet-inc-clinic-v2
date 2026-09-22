# Vet INC Group Control Plane

## Product definition

For veterinary chains, Vet INC is a **controlled price-change implementation console**.

It is not primarily an analysis dashboard, a price-recommendation engine, or a revenue-monitoring product. A central pricing/operations team uses it to carry an already-approved pricing decision across many clinics with clear scope, exceptions, authorization, execution status, and audit history.

> **Approved change set → mapped locations → exceptions resolved → implementation → confirmation → record**

Commercial pricing authority remains with the customer. Vet INC must not be framed as autonomously selecting, approving, or changing prices.

## Primary home screen: enterprise change portfolio

This is an enterprise workspace for teams, not a single-user rollout checklist or one change shown as a dashboard. The entry point is a portfolio of company-wide pricing changes with scope, accountable team, stage, open work, and target date. Selecting a change opens its coordinated team workspace: overview, assigned work, approvals, location progress, and record. Central pricing, finance, regional operations, local clinic leaders, and implementation owners share that context. Technical implementation detail is available within the relevant change/location, not on the portfolio landing screen. The review prototype is illustrative and does not record approvals, assignments, or pricing changes.

The default screen answers team questions:

1. Which company-wide pricing changes are active, pending sign-off, blocked, or complete?
2. What work is assigned to each team or person before the change can move forward?
3. Which clinics, services, local variations, or missing inputs need a decision?
4. Who has approved the current version, and what remains before the organization can proceed?
5. What was confirmed, when, and by whom?

## Team model

A change set has explicit people and responsibilities:

- **Pricing owner** — creates and maintains the proposed company-wide change.
- **Finance / executive approver** — signs off on the authorized version.
- **Regional operations owner** — coordinates location readiness and exceptions.
- **Location lead** — provides or confirms local information when required.
- **Implementation owner** — documents the approved implementation step and confirmation.

The interface should show assigned work, due dates, sign-offs, comments, and a shared activity record beside the change—not hide collaboration behind technical implementation states.

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
