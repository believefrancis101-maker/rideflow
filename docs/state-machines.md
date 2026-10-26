# RideFlow - Stage 3 State Machines

| Field | Value |
|---|---|
| Assessment | Task 3 - API Design and Data Modeling |
| Stage | 3 - Design Decisions and State Machines |
| Status | Draft for approval |
| Baselines | `docs/requirements.md` (Stage 1 - approved), `docs/data-model.md` (Stage 2), `docs/design-decisions.md` (Stage 3 companion) |
| Scope | Design documentation only. No SQL migrations, database tables, seed data, application code, API endpoints or frontend files. |

## 1. Purpose

This document defines the allowed and forbidden state transitions for the RideFlow domain objects that have lifecycle semantics:

1. Trips (five-action lifecycle plus supporting operations).
2. Payments (attempt lifecycle and retry semantics).
3. Driver approval and availability (driver/vehicle status and eligibility).
4. (Reviews are immutable; see audit/review rules.)

It distinguishes database-enforced rules from API or transactional responsibilities, and addresses concurrency, payment retries, review eligibility, auditability, and the three required invalid-insert tests.

## 2. Trip state machine

### 2.1 States

| State | Classification | Meaning |
|---|---|---|
| `requested` | Active | Passenger requested a trip; no driver/vehicle assigned. |
| `accepted` | Active | Assigned driver and vehicle accepted the trip; awaiting arrival. |
| `driver_arriving` | Active | Assigned driver marked arrival. |
| `in_progress` | Active | Trip started; driver completing. |
| `completed` | Terminal | Driver completed; payment outcome recorded. |
| `cancelled` | Terminal | Cancelled before trip start. |
| `expired` | Terminal | Unaccepted request expired. |

Active statuses: `requested`, `accepted`, `driver_arriving`, `in_progress`. Terminal statuses: `completed`, `cancelled`, `expired`.

### 2.2 Allowed transitions

| From | To | Design decision | Governing requirement | Notes |
|---|---|---|---|---|
| `requested` | `accepted` | **Allowed** | R2, BR2/BR4/BR5/BR6 | Conditional update; idempotent; audited. |
| `requested` | `cancelled` | **Allowed** | Supporting operation (A6 policy open) | Cancellation before start. |
| `requested` | `expired` | **Allowed** | Supporting operation (A6) | System expiry. |
| `accepted` | `driver_arriving` | **Allowed** | Supporting operation | Arrival marking. |
| `accepted` | `cancelled` | **Allowed** | Supporting operation (A6 policy open) | Cancellation before start. |
| `driver_arriving` | `in_progress` | **Allowed** | Supporting operation | Start marking. |
| `driver_arriving` | `cancelled` | **Allowed** | Supporting operation (A6 policy open) | Cancellation before start. |
| `in_progress` | `completed` | **Allowed** | R4, BR17 | Completion + payment outcome. |

### 2.3 Forbidden transitions and terminal handling

- `completed`, `cancelled` and `expired` are **terminal**; no transitions out of a terminal state are allowed.
- `in_progress -> cancelled` is **forbidden** in the MVP (cancellation is scoped to before trip start).
- `accepted -> completed` is **forbidden** (completion must traverse `driver_arriving` then `in_progress`).
- Skipped or out-of-order transitions (for example `requested -> in_progress`) are **forbidden**.
- Transition enforcement is database-enforced via a state transition trigger backed by the allowlist above (DD-1), with API/transactional enforcement as the primary mutation path.

### 2.4 Transition semantics and timestamps

Lifecycle timestamps are set atomically with transitions and are constrained by the written model:

- `requested_at` set on request; `accepted_at` on acceptance; `driver_arriving_at` on arrival; `started_at` on start; `completed_at` on completion; `cancelled_at` on cancellation; `expired_at` on expiry.
- Immutable trip fields (`passenger_id`, `fare_minor`, `currency`, `payment_method`, `requested_at`) are trigger-protected; assignment is null-to-set only (BR16).

## 3. Payment state machine

| State | Meaning | Allowed next states | Terminal |
|---|---|---|---|
| `pending` | Attempt created; awaiting outcome (cash confirmation or electronic provider result; may remain pending on timeout). | `succeeded`, `failed` | No |
| `succeeded` | Collection succeeded; at most one per trip. | - | **Yes** |
| `failed` | Collection failed; retry creates a new attempt. | - | **Yes** |

Design decisions:

- Only `pending -> succeeded` and `pending -> failed` are allowed (DD-2); terminal attempts cannot change.
- Cash: driver confirmation at completion yields `succeeded` directly (no external provider call).
- Electronic: system creates `pending`, records provider result as `succeeded`/`failed`; unknown/timeout may remain `pending`.
- Retries create new attempt rows (D3); a failed row is never flipped to succeeded.

## 4. Driver approval and availability state handling

### 4.1 Driver profile status transitions

| From | To | Design decision | Actor |
|---|---|---|---|
| `pending` | `approved` | Allowed | Admin approval |
| `pending` | `rejected` | Allowed | Admin rejection |
| `approved` | `suspended` | Allowed | Admin suspension |
| `suspended` | `approved` | Allowed | Admin reinstatement |

### 4.2 Vehicle status transitions

| From | To | Design decision | Actor |
|---|---|---|---|
| `pending` | `approved` | Allowed | Admin approval |
| `approved` | `suspended` | Allowed | Admin suspension |
| `suspended` | `approved` | Allowed | Admin reinstatement |

### 4.3 Driver availability

Driver availability is designed as a **derived** condition (no availability state/entity), implemented through BR6 checks:

- driver profile `approved`;
- assigned vehicle owned by driver, `approved`, not suspended;
- driver has no active trip;
- trip is `requested` and accepting.

## 5. Database-enforced vs API / transactional responsibilities

| Concern | Database-enforced | API / transactional |
|---|---|---|
| Status value sets | CHECK constraints | - |
| Allowed transitions | Transition triggers (allowlist) | Transactional execution + trigger backstop |
| Immutable fields | Immutability triggers | - |
| Uniqueness / partial unique | Yes | - |
| Foreign keys / checks | Yes | - |
| Idempotency lookup precedence | Key design | Lookup before preconditions |
| Authorization | Ownership design | Per-endpoint enforcement (D9) |
| Fare calculation / snapshot | Fare checks, immutability | Server-side calculation, snapshot |
| Provider outcome recording | Payment transition rules | Provider result ingestion |
| Audit event content | Append-only | Event write within transaction |
| Policy parameters (TTL, cancellation reasons/fees) | - | Operational responsibility |

## 6. Concurrency, retries, review eligibility, auditability and invalid inserts

### 6.1 Concurrency

- Acceptance: conditional update `requested -> accepted` with driver/vehicle assignment in one transaction; partial unique indexes prevent double assignment; losing concurrent callers receive conflict (NFR5).

### 6.2 Payment retries

- Retry creates a new attempt (D3); at most one `succeeded` per trip (BR9/partial unique); idempotent replay returns stored outcome.

### 6.3 Review eligibility

- Only the trip's passenger may review a `completed` trip with an assigned driver; composite FK + unique + completed-trigger + immutability enforce this (BR10-BR11).

### 6.4 Auditability

- Append-only audit events cover trip lifecycle, assignment, fare, payment, review and eligibility/admin actions; no update/delete.

### 6.5 Required invalid-insert tests

1. Second active trip for one passenger -> partial unique active-passenger index (BR3/NFR1).
2. Second successful payment for one trip -> partial unique successful-payment index (BR9/NFR5).
3. Second review for one trip -> unique `reviews.trip_id` (BR10).

Additional negative coverage: unapproved driver acceptance, wrong-owner vehicle assignment, forbidden state transition.

## 7. Summary

- Trip, payment, driver approval/availability state designs are defined above and are consistent with Stages 1 and 2.
- Database-enforced rules backstop API/transactional responsibilities.
- Stage 3 documentation is complete; no SQL/migrations/code created.
