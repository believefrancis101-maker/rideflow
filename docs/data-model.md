# RideFlow - Data Model

| Field | Value |
|---|---|
| Assessment | Task 3 - API Design and Data Modeling |
| Stage | 2 - Entity Model and ER Diagram |
| Status | Draft for approval |
| Baseline | `docs/requirements.md` (approved Stage 1) |
| Scope | Logical/physical PostgreSQL model only; no SQL, migrations, tables or application code |
| Last updated | 2026-10-23 |

This document defines the canonical entities, fields, keys, constraints, relationships, deletion behaviour and requirement traceability for RideFlow. The Mermaid diagram in `docs/er-diagram.md` is a visual projection of this document; where the two differ, this document is authoritative and the diagram must be corrected before implementation.

## 1. Modeling principles

1. **PostgreSQL-first types.** Identifiers are `uuid`; the database default is `gen_random_uuid()`. Timestamps are `timestamptz` in UTC. Money is `bigint` minor units plus a `varchar(3)` ISO 4217 currency. No floating-point or `numeric` money columns are used.
2. **Status values are `text` plus `CHECK` constraints.** This keeps the model PostgreSQL-compatible without depending on mutable enum types. The stage-3 state-machine trigger will restrict transitions; a `CHECK` alone only restricts the value set.
3. **Every entity has `created_at` and `updated_at`.** Both default to `now()` and are `NOT NULL`. Mutable tables use a `set_updated_at` trigger. Immutable/append-only tables set both at insert and reject updates; `updated_at` is retained as a uniform audit convention rather than implying mutation.
4. **UUIDs are identifiers, not authorization.** Every API access still verifies the caller's relationship to the resource. No table grants or RLS policies are assumed in the MVP; authorization is an API concern backed by ownership predicates.
5. **Foreign keys default to `ON DELETE RESTRICT`.** This is deliberate for financial and audit history. Exceptions are documented per relationship, notably telemetry and idempotency retention.
6. **No unnecessary entities.** Current-state fields live on the entity they describe; immutable history is handled by `audit_events`; payment retries are rows in `payments`; fare quotes are not persisted separately in the MVP. Section 7 records the deliberate omissions.
7. **The database is the last line of defence.** Application validation is useful, but the invariants in section 5 are intended to be enforceable with primary keys, foreign keys, unique/partial unique indexes, checks and triggers.
8. **Constraint names below are descriptive.** Final SQL identifiers may differ; the semantics are binding.

## 2. Entity overview

| Entity | Purpose | Primary key | Primary requirements |
|---|---|---|---|
| `users` | Customer and admin accounts. Driver capability is not an account role. | `id` | R1-R5, BR1, BR2, BR13 |
| `driver_profiles` | One-to-one driver capability and approval state attached to a customer user. | `user_id` | R2, BR6 |
| `vehicles` | Driver-owned vehicles that can be assigned to trips. | `id` | R2, R3, BR5, BR6 |
| `trips` | Trip request, lifecycle state, fare/currency snapshot and assignment. | `id` | R1-R5, BR1-BR9, BR12, BR15-BR17 |
| `trip_location_samples` | Append-only location telemetry for trip progress. | `id` | R3, NFR6, A10 |
| `payments` | One row per cash/electronic collection attempt; supports retries. | `id` | R4, BR9, BR15, BR17 |
| `reviews` | One immutable passenger review per completed trip. | `id` | R5, BR10, BR11 |
| `audit_events` | Append-only actor/action/entity history. | `id` | NFR4, BR14 |
| `idempotency_keys` | Stored responses for idempotent unsafe operations and payment retries. | `id` | R1, R2, R4, NFR7, A9 |

## 3. Relationships and cardinalities

| Parent / referenced entity | Child / referencing entity | Cardinality | Foreign key and enforcement |
|---|---|---|---|
| `users` | `driver_profiles` | 1 user : 0 or 1 profile | `driver_profiles.user_id` is both PK and FK to `users.id`, so one profile per user. |
| `users` | `trips` (as passenger) | 1 user : 0..* trips | `trips.passenger_id NOT NULL` FK to `users.id`; every trip has exactly one passenger. |
| `driver_profiles` | `vehicles` | 1 driver : 0..* vehicles | `vehicles.driver_id NOT NULL` FK to `driver_profiles.user_id`; every vehicle has one owner. |
| `driver_profiles` | `trips` (as driver) | 1 driver : 0..* trips | `trips.driver_id` nullable FK to `driver_profiles.user_id`; a trip has zero or one assigned driver. |
| `vehicles` | `trips` (as vehicle) | 1 vehicle : 0..* trips | `trips.vehicle_id` nullable FK to `vehicles.id`; a trip has zero or one assigned vehicle. The composite `(driver_id, vehicle_id)` FK to `vehicles(driver_id, id)` enforces that the vehicle belongs to the assigned driver. |
| `trips` | `trip_location_samples` | 1 trip : 0..* samples | `trip_location_samples.trip_id NOT NULL` FK to `trips.id`; samples are child telemetry. |
| `trips` | `payments` | 1 trip : 0..* attempts | `payments.trip_id NOT NULL` FK to `trips.id`; a trip may have failed attempts and at most one successful attempt. |
| `trips` | `reviews` | 1 trip : 0 or 1 review | `reviews.trip_id` is `NOT NULL` and `UNIQUE`; one review per trip. |
| `users` | `reviews` (as author/passenger) | 1 user : 0..* reviews | `reviews.passenger_id NOT NULL` FK to `users.id`, plus composite `(trip_id, passenger_id)` ownership FK. |
| `users` | `audit_events` (as actor) | 1 user : 0..* events | `audit_events.actor_user_id` nullable FK to `users.id`; null for `system` actors. |
| `users` | `idempotency_keys` | 1 user : 0..* keys | `idempotency_keys.principal_user_id NOT NULL` FK to `users.id`. |

### 3.1 Driver and vehicle ownership

`driver_profiles.user_id` is the driver profile's primary key **and** foreign key to `users.id`. This is a deliberate one-to-one extension of the user account:

- it makes `trips.driver_id` the driver's user ID, so `passenger_id <> driver_id` is a simple same-table check;
- it avoids a separate synthetic `driver_profile_id` that would coexist with the user ID;
- it lets `vehicles.driver_id` and `trips.driver_id` reference the same stable identifier.

Vehicle ownership is enforced in two layers:

1. `vehicles.driver_id` establishes the owner.
2. `trips (driver_id, vehicle_id)` references `vehicles (driver_id, id)`.

The composite FK is the critical rule: a trip cannot assign driver A with a vehicle owned by driver B, even if a caller submits that pair directly.

### 3.2 Active-trip model

A trip is active when its status is one of `requested`, `accepted`, `driver_arriving` or `in_progress`. The model enforces per-capacity uniqueness with partial unique indexes:

- one active trip per `passenger_id`;
- one active trip per `driver_id`, when assigned;
- one active trip per `vehicle_id`, when assigned.

A passenger and driver may not be the same user on one trip (`passenger_id <> driver_id`). The cross-capacity case - a dual-capability user being on two different active trips, one as passenger and one as driver - is an open Stage 1 decision (A12) and is flagged in section 9.

## 4. Entity definitions

The following tables define every field, its PostgreSQL type, nullability, default and key constraints. `No` means `NOT NULL`; `Yes` means nullable.

### 4.1 `users`

**Purpose:** A human account. Account roles are `customer` and `admin`; driver capability is expressed separately by `driver_profiles`.

| Field | Type | Null | Default | Constraints and notes |
|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | Primary key. |
| `role` | `text` | No | `'customer'` | `CHECK (role IN ('customer','admin'))`. |
| `status` | `text` | No | `'active'` | `CHECK (status IN ('active','disabled'))`. Disabled accounts cannot authenticate. |
| `full_name` | `text` | No | - | `CHECK (char_length(btrim(full_name)) > 0)`. |
| `email` | `text` | No | - | Normalized lowercase; `CHECK (email = lower(email) AND char_length(email) BETWEEN 3 AND 320)`. Unique. |
| `phone` | `text` | Yes | `NULL` | `CHECK (phone IS NULL OR char_length(phone) BETWEEN 7 AND 32)`. Format validation belongs to the API. |
| `deleted_at` | `timestamptz` | Yes | `NULL` | Soft-delete marker; `CHECK (deleted_at IS NULL OR (status='disabled' AND deleted_at >= created_at))`. |
| `created_at` | `timestamptz` | No | `now()` | UTC creation time. |
| `updated_at` | `timestamptz` | No | `now()` | UTC last-mutation time; maintained by trigger. |

**Keys and constraints:**

- Primary key: `(id)`.
- Unique: `email` (stored lowercase, so a plain unique constraint is sufficient).
- Check: role, status, lowercase email, email length, non-empty name, phone length, soft-delete ordering and `deleted_at` implies `status='disabled'`.
- Trigger `users_role_immutable`: `role` cannot change after insert in the MVP. Admin provisioning is a controlled setup operation, not a client profile edit. This keeps the driver-profile/passenger eligibility rules stable; a future role-change workflow must revalidate active trips and driver eligibility.
- No foreign keys; `users` is the identity root.
- Index: unique `users(email)`. A role/status index is not justified by the five core queries; admin list endpoints can use bounded pagination and should add an index only if evidence requires it.

**Deletion/retention:** Soft delete only. Setting `deleted_at` and `status='disabled'` prevents authentication while preserving references from trips, reviews and audit history. Hard delete is not exposed. The unique email remains occupied while the row exists; re-registration with the same address is therefore blocked unless an approved anonymisation process changes or releases it. Complete erasure/anonymisation is a Stage 3 policy decision (A7); if implemented, it must not silently orphan financial or audit records.

### 4.2 `driver_profiles`

**Purpose:** The one-to-one driver capability for a customer user. The profile's existence is separate from eligibility; eligibility is `status='approved'` plus the vehicle and active-trip checks in BR6.

| Field | Type | Null | Default | Constraints and notes |
|---|---|---|---|---|
| `user_id` | `uuid` | No | - | Primary key **and** FK to `users(id)`. One driver profile per user. |
| `status` | `text` | No | `'pending'` | `CHECK (status IN ('pending','approved','suspended','rejected'))`. |
| `approved_at` | `timestamptz` | Yes | `NULL` | `CHECK (status <> 'approved' OR approved_at IS NOT NULL)`; `CHECK (approved_at IS NULL OR approved_at >= created_at)`. |
| `created_at` | `timestamptz` | No | `now()` | UTC creation time. |
| `updated_at` | `timestamptz` | No | `now()` | Maintained by trigger when status changes. |

**Keys and constraints:**

- Primary key: `(user_id)`.
- Foreign key: `user_id` -> `users(id)` `ON DELETE RESTRICT`.
- Check: status value set; approved status requires `approved_at`; approval cannot precede creation.
- Trigger `driver_profiles_require_customer_role`: the referenced user must have `role='customer'`. This prevents an admin account from acquiring driver capability by direct insert and keeps the role vocabulary consistent. A companion check on `users.role` updates rejects changing a user with a driver profile to `admin`; otherwise the profile would outlive its eligibility invariant.
- The approval actor is not stored as a column; the `audit_events` record for the status change is the authoritative record of who approved it. This avoids duplicating actor identity on the profile.
- Index: `driver_profiles(status)` for eligibility/admin queries. The PK covers lookup by user.

**Deletion/retention:** No delete operation. Rejection and suspension are represented by status, not row deletion. A driver profile referenced by vehicles or trips cannot be removed because of restrictive FKs. A user with an approved profile who is later disabled must fail authentication/eligibility rather than relying on UUID secrecy.

### 4.3 `vehicles`

**Purpose:** A vehicle owned by exactly one driver. A driver may have multiple vehicles; a trip may select one at acceptance.

| Field | Type | Null | Default | Constraints and notes |
|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | Primary key. |
| `driver_id` | `uuid` | No | - | FK to `driver_profiles(user_id)`; the owning driver. |
| `license_plate` | `text` | No | - | Normalized uppercase; `CHECK (license_plate = upper(license_plate) AND char_length(license_plate) BETWEEN 2 AND 16)`. Unique. |
| `make` | `text` | No | - | `CHECK (char_length(btrim(make)) > 0)`. |
| `model` | `text` | No | - | `CHECK (char_length(btrim(model)) > 0)`. |
| `color` | `text` | Yes | `NULL` | `CHECK (color IS NULL OR char_length(color) <= 40)`. |
| `status` | `text` | No | `'pending'` | `CHECK (status IN ('pending','approved','suspended'))`. |
| `approved_at` | `timestamptz` | Yes | `NULL` | `CHECK (status <> 'approved' OR approved_at IS NOT NULL)`; `CHECK (approved_at IS NULL OR approved_at >= created_at)`. |
| `created_at` | `timestamptz` | No | `now()` | UTC creation time. |
| `updated_at` | `timestamptz` | No | `now()` | Maintained by trigger when status or details change. |

**Keys and constraints:**

- Primary key: `(id)`.
- Foreign key: `driver_id` -> `driver_profiles(user_id)` `ON DELETE RESTRICT`.
- Unique: `license_plate`; `(driver_id, id)` to support the composite ownership FK from `trips`.
- Check: plate uppercase/length, non-empty make/model, color length, status value set, approved status requires `approved_at`, approval not before creation.
- Index: unique `vehicles(license_plate)`; `vehicles(driver_id, status)` for eligible-vehicle lookup; unique `(driver_id, id)`.
- Ownership transfer is not an MVP operation. Updating `driver_id` while any trip references the `(driver_id, id)` pair is rejected by the composite FK. Any future transfer must be an explicit audited operation that first proves no active or historical assignment depends on the old pair.

**Deletion/retention:** No delete operation. A vehicle is suspended rather than removed. The restrictive FKs preserve assignment history. A suspended vehicle cannot be newly assigned; existing active-trip handling is a Stage 3 operational exception.

### 4.4 `trips`

**Purpose:** The trip aggregate: passenger request, optional driver/vehicle assignment, lifecycle status, route, and the immutable agreed fare/currency snapshot.

| Field | Type | Null | Default | Constraints and notes |
|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | Primary key. |
| `passenger_id` | `uuid` | No | - | FK to `users(id)`; exactly one passenger. |
| `driver_id` | `uuid` | Yes | `NULL` | FK to `driver_profiles(user_id)`; the driver's user ID. Null until acceptance. |
| `vehicle_id` | `uuid` | Yes | `NULL` | FK to `vehicles(id)`. Null until acceptance; must belong to `driver_id` through the composite FK. |
| `status` | `text` | No | `'requested'` | `CHECK (status IN ('requested','accepted','driver_arriving','in_progress','completed','cancelled','expired'))`. |
| `pickup_latitude` | `numeric(9,6)` | No | - | `CHECK (pickup_latitude BETWEEN -90 AND 90)`. |
| `pickup_longitude` | `numeric(9,6)` | No | - | `CHECK (pickup_longitude BETWEEN -180 AND 180)`. |
| `dropoff_latitude` | `numeric(9,6)` | No | - | `CHECK (dropoff_latitude BETWEEN -90 AND 90)`. |
| `dropoff_longitude` | `numeric(9,6)` | No | - | `CHECK (dropoff_longitude BETWEEN -180 AND 180)`. |
| `pickup_address` | `text` | Yes | `NULL` | Human-readable label; `CHECK (pickup_address IS NULL OR char_length(pickup_address) <= 500)`. |
| `dropoff_address` | `text` | Yes | `NULL` | Human-readable label; `CHECK (dropoff_address IS NULL OR char_length(dropoff_address) <= 500)`. |
| `fare_minor` | `bigint` | No | - | Agreed fare in integer minor units; `CHECK (fare_minor > 0)`. Immutable after insert. |
| `currency` | `varchar(3)` | No | - | `CHECK (currency ~ '^[A-Z]{3}$')`. ISO 4217; no FX conversion. Immutable. |
| `payment_method` | `text` | No | - | `CHECK (payment_method IN ('cash','electronic'))`. Selected at request; immutable in the MVP. |
| `requested_at` | `timestamptz` | No | `now()` | Request creation time. |
| `accepted_at` | `timestamptz` | Yes | `NULL` | Set atomically with the driver/vehicle assignment. |
| `driver_arriving_at` | `timestamptz` | Yes | `NULL` | Set when the assigned driver enters `driver_arriving`. |
| `started_at` | `timestamptz` | Yes | `NULL` | Set when the trip enters `in_progress`. |
| `completed_at` | `timestamptz` | Yes | `NULL` | Set when the trip enters `completed`; terminal. |
| `cancelled_at` | `timestamptz` | Yes | `NULL` | Set when the trip enters `cancelled`; terminal. |
| `cancellation_reason` | `text` | Yes | `NULL` | `CHECK (cancellation_reason IS NULL OR char_length(cancellation_reason) <= 500)`. |
| `expired_at` | `timestamptz` | Yes | `NULL` | Set when an unaccepted request enters `expired`; terminal. |
| `created_at` | `timestamptz` | No | `now()` | UTC row creation time. |
| `updated_at` | `timestamptz` | No | `now()` | Maintained by trigger on lifecycle changes. |

**Keys and constraints:**

- Primary key: `(id)`.
- Foreign keys:
  - `passenger_id` -> `users(id)` `ON DELETE RESTRICT`.
  - `driver_id` -> `driver_profiles(user_id)` `ON DELETE RESTRICT`.
  - `vehicle_id` -> `vehicles(id)` `ON DELETE RESTRICT`.
  - Composite `(driver_id, vehicle_id)` -> `vehicles(driver_id, id)`, enforcing ownership consistency.
- Unique:
  - `(id, passenger_id)` for the review ownership FK.
  - `(id, fare_minor, currency, payment_method)` for the payment snapshot FK.
  - Partial unique `(passenger_id) WHERE status IN (active statuses)`.
  - Partial unique `(driver_id) WHERE driver_id IS NOT NULL AND status IN (active statuses)`.
  - Partial unique `(vehicle_id) WHERE vehicle_id IS NOT NULL AND status IN (active statuses)`.
- Check: status value set; fare > 0; currency shape; payment method; coordinate ranges; address lengths; assignment both-or-neither; passenger differs from driver.
- Trigger `trips_passenger_must_be_customer`: on insert, `passenger_id` must reference a user with `role='customer'` and `status='active'`. This enforces the Stage 1 decision that admins are oversight-only and do not act as passengers. The passenger role is immutable via `users_role_immutable`, and `passenger_id` is immutable after insert.
- Check: a `requested` trip has no assignment and no later lifecycle timestamp.
- Check: `accepted`, `driver_arriving`, `in_progress` and `completed` require an assigned driver and vehicle and a non-null `accepted_at`; `driver_arriving` requires `driver_arriving_at`; `in_progress` and `completed` require `started_at`; `completed` requires `completed_at`; `cancelled` requires `cancelled_at`; `expired` requires `expired_at`, no assignment and no `accepted_at`. `cancellation_reason` is allowed only with `cancelled`. `completed`, `cancelled` and `expired` are mutually exclusive.
- Check: `accepted_at >= requested_at`, `driver_arriving_at >= accepted_at`, `started_at >= accepted_at`, `completed_at >= started_at` and `cancelled_at >= requested_at` when the respective timestamps are present.
- Trigger: immutable columns `passenger_id`, `fare_minor`, `currency`, `payment_method`, `requested_at` cannot change after insert.
- Trigger: `driver_id` and `vehicle_id` may only move from both-null to both-set; once set they cannot change. This enforces BR16.
- Trigger: status transitions are restricted to the Stage 3 state machine; the status check alone is not the state machine. The happy path is `requested -> accepted -> driver_arriving -> in_progress -> completed`; cancellation/expiry transitions are defined in Stage 3.
- Trigger: `updated_at` maintenance.

**Indexes:**

- `trips(passenger_id, created_at DESC)` for passenger current/history access.
- `trips(driver_id, created_at DESC)` for assigned-driver current/history access.
- Partial `trips(created_at) WHERE status='requested'` for the available-trip queue.
- The three partial unique active-trip indexes above.
- Unique `(id, passenger_id)` and `(id, fare_minor, currency, payment_method)` are constraint indexes, not general-purpose search indexes.
- No index on every status/column combination. Additional indexes require query-plan evidence.

**Deletion/retention:** No delete operation. `completed`, `cancelled` and `expired` are terminal states. Restrictive FKs preserve the trip's financial and audit relationships. Retention and any privacy erasure are Stage 3 policy decisions (A7, A14); a hard delete must be an explicit controlled process, not an API capability.

### 4.5 `trip_location_samples`

**Purpose:** Append-only telemetry used to show current trip progress. The latest sample is the newest row for the trip; historical samples support tracking and retention policy.

| Field | Type | Null | Default | Constraints and notes |
|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | Primary key. |
| `trip_id` | `uuid` | No | - | FK to `trips(id)`. |
| `latitude` | `numeric(9,6)` | No | - | `CHECK (latitude BETWEEN -90 AND 90)`. |
| `longitude` | `numeric(9,6)` | No | - | `CHECK (longitude BETWEEN -180 AND 180)`. |
| `accuracy_meters` | `numeric(7,2)` | Yes | `NULL` | `CHECK (accuracy_meters IS NULL OR accuracy_meters >= 0)`. |
| `recorded_at` | `timestamptz` | No | - | Device-reported sample time, stored in UTC. |
| `created_at` | `timestamptz` | No | `now()` | Server receipt time. |
| `updated_at` | `timestamptz` | No | `now()` | Set equal to `created_at`; updates are rejected. |

**Keys and constraints:**

- Primary key: `(id)`.
- Foreign key: `trip_id` -> `trips(id)` `ON DELETE CASCADE` (recommended; see D6).
- Check: latitude/longitude ranges; non-negative accuracy.
- Immutable/append-only trigger rejects `UPDATE`. `DELETE` is allowed only to the retention job (and through trip cascade), not through the API.
- No `driver_id` column. The driver is derived from `trips.driver_id`; duplicating it on every high-volume sample would be unjustified. Insert authorization checks that the caller is the assigned driver and that the trip is active; the FK and coordinate checks remain database-enforced.
- Index: `trip_location_samples(trip_id, recorded_at DESC, id DESC)` supports the latest sample and bounded history. The `id DESC` tie-breaker makes “latest” deterministic when timestamps collide.

**Deletion/retention:** Append-only telemetry. Proposed MVP retention is 30 days after trip completion, after which a controlled retention job deletes the samples (A10). The `ON DELETE CASCADE` choice means a controlled trip deletion would also remove telemetry; financial and audit rows are not cascaded. The exact period and deletion mechanism remain Stage 3 decisions.

### 4.6 `payments`

**Purpose:** One row per cash or electronic collection attempt. The set of rows for a trip is its payment history; retries are new attempts, never mutations of a prior successful attempt.

| Field | Type | Null | Default | Constraints and notes |
|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | Primary key. |
| `trip_id` | `uuid` | No | - | FK to `trips(id)`. |
| `attempt_no` | `integer` | No | - | `CHECK (attempt_no > 0)`; unique with `trip_id`. |
| `method` | `text` | No | - | `CHECK (method IN ('cash','electronic'))`; must equal the trip's payment method. |
| `amount_minor` | `bigint` | No | - | `CHECK (amount_minor > 0)`; must equal the trip's agreed fare. |
| `currency` | `varchar(3)` | No | - | `CHECK (currency ~ '^[A-Z]{3}$')`; must equal the trip currency. |
| `status` | `text` | No | `'pending'` | `CHECK (status IN ('pending','succeeded','failed'))`. |
| `provider_reference` | `text` | Yes | `NULL` | External provider identifier; unique when present. |
| `failure_code` | `text` | Yes | `NULL` | Bounded provider/application failure code; no free-text secrets. |
| `settled_at` | `timestamptz` | Yes | `NULL` | Set when the attempt reaches `succeeded` or `failed`. |
| `created_at` | `timestamptz` | No | `now()` | Attempt creation time. |
| `updated_at` | `timestamptz` | No | `now()` | Changes only on the controlled status transition. |

**Keys and constraints:**

- Primary key: `(id)`.
- Foreign key: `trip_id` -> `trips(id)` `ON DELETE RESTRICT`.
- Composite foreign key: `(trip_id, amount_minor, currency, method)` -> `trips(id, fare_minor, currency, payment_method)`. This is the declarative guarantee that every attempt preserves the trip's fare/currency/method snapshot and that no client can submit a different amount.
- Unique: `(trip_id, attempt_no)`, preventing duplicate attempt numbering.
- Partial unique: `(trip_id) WHERE status='succeeded'`, preventing a second successful collection for a trip.
- Partial unique: `(provider_reference) WHERE provider_reference IS NOT NULL`, preventing duplicate provider callbacks/references.
- Check: status, method, positive amount, currency shape, attempt number positive; `settled_at` is present for `succeeded`/`failed` and absent for `pending`; cash attempts cannot carry a provider reference.
- Trigger: only `pending -> succeeded` and `pending -> failed` are allowed. A terminal attempt cannot change. Retrying after failure inserts a new row with the next `attempt_no`; a failed row is never flipped to succeeded, preserving attempt history.
- Trigger: `updated_at` maintenance on the controlled status change.
- Index: `payments(trip_id, created_at DESC)` for payment history; the unique/partial-unique constraints provide the duplicate-prevention access paths.

**Cash behaviour:** The assigned driver records a cash attempt with `method='cash'`, `status='succeeded'`, `settled_at` set, and no provider reference. A duplicate cash confirmation is either an idempotent replay or a rejected second success.

**Electronic behaviour:** The system creates a `pending` attempt, records a provider reference when available, and transitions it to `succeeded` or `failed`. A timeout may remain `pending`; a retry creates a new attempt. The assessment simulates provider outcomes; no gateway is integrated.

**Deletion/retention:** No delete operation. Payment attempts are financial history and are retained under the Stage 3 financial-retention decision. The restrictive trip FK and partial unique success index remain in force even if a trip is eventually archived.

### 4.7 `reviews`

**Purpose:** One immutable passenger review of a completed trip. The reviewed driver is derived from the trip rather than duplicated on the review.

| Field | Type | Null | Default | Constraints and notes |
|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | Primary key. |
| `trip_id` | `uuid` | No | - | FK to `trips(id)`; `UNIQUE`, so one review per trip. |
| `passenger_id` | `uuid` | No | - | FK to `users(id)`; must equal the trip's passenger. |
| `rating` | `smallint` | No | - | `CHECK (rating BETWEEN 1 AND 5)`. |
| `comment` | `text` | Yes | `NULL` | `CHECK (comment IS NULL OR char_length(comment) <= 2000)`. |
| `created_at` | `timestamptz` | No | `now()` | Review creation time. |
| `updated_at` | `timestamptz` | No | `now()` | Set equal to `created_at`; updates are rejected. |

**Keys and constraints:**

- Primary key: `(id)`.
- Foreign keys:
  - `trip_id` -> `trips(id)` `ON DELETE RESTRICT`.
  - `passenger_id` -> `users(id)` `ON DELETE RESTRICT`.
  - Composite `(trip_id, passenger_id)` -> `trips(id, passenger_id)`, guaranteeing the reviewer is the trip's passenger.
- Unique: `trip_id` (one review per trip).
- Check: rating range and comment length.
- Trigger `reviews_require_completed_trip`: on insert, the referenced trip must have `status='completed'` and a non-null `driver_id`. The driver is then unambiguous from `trips.driver_id`; no `reviews.driver_id` copy is needed.
- Trigger: reject `UPDATE` and `DELETE` to enforce BR11. The review's `updated_at` remains equal to `created_at`.
- Index: unique `reviews(trip_id)`; `reviews(passenger_id, created_at DESC)` for a passenger's review history. Driver review aggregates join `trips` on `trip_id` and use `trips(driver_id, created_at DESC)`; no redundant driver ID index is added.

**Deletion/retention:** No delete operation and no soft-delete column. Reviews are immutable in the MVP. Any retention/erasure action is a Stage 3 policy decision and must be an explicit controlled process that does not silently mutate a review.

### 4.8 `audit_events`

**Purpose:** Append-only history of security- and business-relevant changes: trip lifecycle, assignment, fare-related changes, payments, reviews, driver/vehicle eligibility and admin actions.

| Field | Type | Null | Default | Constraints and notes |
|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | Primary key. |
| `actor_type` | `text` | No | - | `CHECK (actor_type IN ('customer','admin','system'))`. |
| `actor_user_id` | `uuid` | Yes | `NULL` | FK to `users(id)`; required for customer/admin actors, null for system. |
| `action` | `text` | No | - | `CHECK (char_length(action) BETWEEN 1 AND 100)`. |
| `entity_type` | `text` | No | - | `CHECK (entity_type ~ '^[a-z][a-z0-9_]{0,63}$')`. |
| `entity_id` | `uuid` | No | - | Target entity identifier; polymorphic, so no direct FK. |
| `before_data` | `jsonb` | Yes | `NULL` | Relevant prior values; no secrets or full payment credentials. |
| `after_data` | `jsonb` | Yes | `NULL` | Relevant new values; no secrets or full payment credentials. |
| `metadata` | `jsonb` | Yes | `NULL` | Request/correlation/reason context, bounded and non-secret. |
| `created_at` | `timestamptz` | No | `now()` | Event time. |
| `updated_at` | `timestamptz` | No | `now()` | Set equal to `created_at`; updates are rejected. |

**Keys and constraints:**

- Primary key: `(id)`.
- Foreign key: `actor_user_id` -> `users(id)` `ON DELETE RESTRICT`.
- Check: actor value set and consistency: `(actor_type='system' AND actor_user_id IS NULL) OR (actor_type IN ('customer','admin') AND actor_user_id IS NOT NULL)`.
- Check: non-empty action and valid entity-type token.
- Append-only trigger rejects `UPDATE` and `DELETE`. There is no soft-delete column.
- `entity_id` is not a foreign key because the audit table is polymorphic across trips, payments, reviews, driver profiles and vehicles. Referential integrity for the audited entity is the responsibility of the writing transaction; the audit row remains valid even if a future retention process removes the target.
- Indexes: `audit_events(entity_type, entity_id, created_at DESC)` for entity history; `audit_events(actor_user_id, created_at DESC)` for actor history. The actor index is partial only if evidence later shows system events dominate; it is not pre-optimised.

**Deletion/retention:** Append-only and not casually deletable (BR14). No update or delete API. Retention beyond the MVP is a Stage 3 decision; any archival process must preserve immutability and audit access. Actor users are soft-deleted, so the FK remains valid.

### 4.9 `idempotency_keys`

**Purpose:** Persist the result of unsafe operations so retries return the original response rather than re-executing a state change. Used by trip request, acceptance, completion and payment-attempt creation.

| Field | Type | Null | Default | Constraints and notes |
|---|---|---|---|---|
| `id` | `uuid` | No | `gen_random_uuid()` | Primary key. |
| `principal_user_id` | `uuid` | No | - | FK to `users(id)`; the authenticated caller. |
| `operation` | `text` | No | - | Stable operation name, e.g. `trip.request`, `trip.accept`, `trip.complete`, `payment.attempt`. |
| `key` | `text` | No | - | Client-supplied idempotency key; `CHECK (char_length(key) BETWEEN 8 AND 255)`. |
| `request_hash` | `text` | No | - | SHA-256 hex fingerprint of the canonical request; `CHECK (request_hash ~ '^[0-9a-f]{64}$')`. |
| `response_status` | `smallint` | No | - | `CHECK (response_status BETWEEN 200 AND 599)`. |
| `response_body` | `jsonb` | No | - | Stored response representation; no secrets. |
| `resource_type` | `text` | Yes | `NULL` | Optional resource family, e.g. `trip` or `payment`. |
| `resource_id` | `uuid` | Yes | `NULL` | Optional created/affected resource ID; not a polymorphic FK. |
| `created_at` | `timestamptz` | No | `now()` | Record creation time. |
| `updated_at` | `timestamptz` | No | `now()` | Set equal to `created_at`; updates are rejected. |
| `expires_at` | `timestamptz` | No | - | `CHECK (expires_at > created_at)`. TTL is an API design decision (A9). |

**Keys and constraints:**

- Primary key: `(id)`.
- Foreign key: `principal_user_id` -> `users(id)` `ON DELETE CASCADE` (ephemeral records; see deletion below).
- Unique: `(principal_user_id, operation, key)`. A retry with the same key is a lookup; a different payload under the same key is a conflict.
- Check: operation/key/hash/status/expiry constraints above.
- The table stores completed responses only. Concurrent first requests race on the unique key; one inserts the result and the other reads the stored response or retries. The idempotency lookup must precede current-state preconditions so a legitimate replay is not rejected by an active-trip or already-accepted check.
- Append-only: no update path. `updated_at` equals `created_at`.
- Index: `idempotency_keys(expires_at)` for TTL cleanup. The unique constraint covers lookup.

**Deletion/retention:** Ephemeral operational data, not business history. Expired keys may be deleted by a controlled TTL job; keys cascade if a user is ever hard-deleted. They are excluded from the financial/audit retention guarantee.

## 5. Cross-entity invariants and enforcement

The model intentionally spreads enforcement across keys, checks, partial unique indexes and triggers. The following table states which mechanism prevents each critical invalid state.

| Invariant | Enforcement | Why it cannot be a casual application-only check |
|---|---|---|
| A trip has exactly one passenger | `trips.passenger_id NOT NULL` FK | Null and dangling references are impossible. |
| A trip has at most one driver and one vehicle, assigned together | Single nullable `driver_id`/`vehicle_id` columns; both-or-neither check; composite ownership FK | A second assignment would require another row or a broken FK, not just a second column value. |
| Assigned vehicle belongs to assigned driver | Composite FK `(driver_id, vehicle_id)` -> `vehicles(driver_id, id)` | A direct insert cannot pair driver A with vehicle B. |
| Passenger and driver are different users | `CHECK (driver_id IS NULL OR passenger_id <> driver_id)` | Driver profile IDs are user IDs, so this is a direct comparison. |
| One active trip per passenger | Partial unique `(passenger_id) WHERE status IN (active)` | Two concurrent active rows for the same passenger are rejected. |
| One active trip per driver | Partial unique `(driver_id) WHERE driver_id IS NOT NULL AND status IN (active)` | Prevents a driver holding two active trips. |
| One active trip per vehicle | Partial unique `(vehicle_id) WHERE vehicle_id IS NOT NULL AND status IN (active)` | Prevents the same vehicle being assigned to two active trips. |
| Only approved drivers with eligible vehicles accept | `driver_profiles.status` + `vehicles.status` checks at acceptance inside the assignment transaction; trigger validation for role | Acceptance is a state-changing transaction; a static FK alone cannot express all eligibility predicates. |
| Fare and currency are preserved | Immutable `trips.fare_minor`, `trips.currency`, `payment_method` trigger; `payments` composite FK to that tuple | Payment rows cannot carry a different amount/currency/method from the trip. |
| One successful collection per trip | Partial unique `(trip_id) WHERE status='succeeded'`; unique provider reference; idempotency | A retry or provider callback cannot create a second success. |
| Reviews belong to the trip's passenger | Composite FK `(trip_id, passenger_id)` -> `trips(id, passenger_id)` | A review cannot be written by a different user, even with a guessed trip UUID. |
| Reviews only concern completed trips | Insert trigger requiring `trips.status='completed'` and assigned driver | A review cannot be attached to a requested, active or cancelled trip. |
| Review target driver is correct | Derived from `trips.driver_id`; assignment is immutable after acceptance | No duplicate driver ID can drift from the trip's driver. |
| One review per trip | `reviews.trip_id UNIQUE` | A second insert is rejected at the database. |
| Reviews are immutable | Update/delete trigger | BR11 is enforced, not merely omitted from the UI. |
| Status follows the state machine | Status check plus Stage 3 transition trigger | The check limits vocabulary; the trigger limits transitions. |
| Financial/audit history is not casually deleted | No delete paths, restrictive FKs, append-only triggers, retention process | Ordinary application code cannot erase history. |
| UUIDs are not authorization | API ownership/assignment checks; UUID opacity alone grants nothing | A leaked identifier is not a capability. |
| Idempotent replay | Unique `(principal, operation, key)` plus request hash comparison | A replay returns the original result; a different payload is rejected. |

### 5.1 Status vocabulary and transition boundary

The trip status set is `requested`, `accepted`, `driver_arriving`, `in_progress`, `completed`, `cancelled`, `expired`. `requested`, `accepted`, `driver_arriving` and `in_progress` are active; the other three are terminal. Payment status is a separate domain (`pending`, `succeeded`, `failed`). Driver profile and vehicle statuses are also separate domains.

The Stage 3 state machine must define the complete allowed/forbidden transition matrix and enforce it with a trigger. The data model reserves the columns needed for that enforcement (`status`, lifecycle timestamps, terminal timestamps). It does not claim that a single `CHECK` constraint is a state machine.

### 5.2 Timestamp and immutability conventions

- `created_at` and `updated_at` exist on every entity and are `NOT NULL` with `now()` defaults.
- Mutable entities (`users`, `driver_profiles`, `vehicles`, `trips`, `payments`) use a `set_updated_at` trigger. `updated_at` changes only when a permitted mutation occurs.
- Append-only entities (`trip_location_samples`, `reviews`, `audit_events`, `idempotency_keys`) set both timestamps at insert and reject updates. `updated_at` is retained for schema uniformity; it is not a claim that the row is editable.
- `payments` permits only `pending -> succeeded` or `pending -> failed`; after settlement, the row is immutable. A retry is a new row.
- `trips` permits lifecycle updates, but `passenger_id`, `fare_minor`, `currency`, `payment_method` and `requested_at` are immutable; assignment is null-to-set only; status transitions are controlled.
- `deleted_at` is present only on `users`. Other entities use statuses, terminal states or explicit retention processes rather than a blanket soft-delete column.
- All timestamps are stored in UTC (`timestamptz`). Display-time localisation is outside the MVP.

## 6. Deletion, retention and data lifecycle

The MVP exposes no delete endpoints for business records. BR14 requires restrictive foreign keys and protected financial/audit history; the database must not make destructive operations convenient.

| Entity | Timestamp convention | Deletion / retention behaviour |
|---|---|---|
| `users` | `created_at`; `updated_at` on profile/status change | Soft delete via `deleted_at` plus `status='disabled'`. No hard delete through the API. Email remains unique until an approved anonymisation process changes it. |
| `driver_profiles` | `created_at`; `updated_at` on status change | No delete. Rejected/suspended states are statuses. Restrictive FKs preserve vehicles and trip history. |
| `vehicles` | `created_at`; `updated_at` on detail/status change | No delete. Suspension is a status. Ownership transfer is out of scope and is blocked while referenced by trips. |
| `trips` | `created_at`; `updated_at` on lifecycle change | No delete. Terminal statuses are `completed`, `cancelled`, `expired`. Restrictive FKs from payments/reviews and audit linkage preserve history. |
| `trip_location_samples` | Both timestamps set at insert; updates rejected | Append-only. A retention job may delete samples after the approved period; proposed 30 days after completion (A10). `ON DELETE CASCADE` from a controlled trip deletion is proposed (D6). |
| `payments` | `created_at`; `updated_at` only on pending-to-terminal transition | No delete. Financial history is retained. Restrictive trip FK; one-success and provider-reference uniqueness remain enforceable during archival. |
| `reviews` | Both timestamps set at insert; updates/deletes rejected | Immutable and not deletable through the API. Retention/erasure is a Stage 3 policy decision; any exceptional process must be explicit and audited. |
| `audit_events` | Both timestamps set at insert; updates/deletes rejected | Append-only. No update/delete API; actor FK is restrictive. Retention/archival must preserve the audit record. |
| `idempotency_keys` | Both timestamps set at insert; updates rejected | Ephemeral. Expired rows may be removed by a TTL job; rows cascade if a user is hard-deleted. Not part of financial/audit retention. |

### 6.1 Why only `users` has `deleted_at`

A blanket `deleted_at` column on every table would create ambiguous states: a soft-deleted trip could still satisfy an active-trip partial index, a soft-deleted payment could look like a reversal, and a soft-deleted review would still occupy the one-review unique key. Instead:

- account removal uses `users.deleted_at`;
- driver/vehicle unavailability uses status;
- trip termination uses terminal status;
- payment reversal is not modelled in the MVP (it would be a new financial fact, not a delete);
- location and idempotency data have time-based retention;
- reviews and audit history are explicitly immutable.

### 6.2 Retention decisions still open

The schema reserves the fields needed for retention (`created_at`, terminal timestamps, `expires_at`) but does not claim a legal retention period. The following remain Stage 3 decisions: user erasure/anonymisation (A7), location retention (A10), idempotency TTL (A9), and financial/audit retention. Any chosen policy must be implemented as a controlled, auditable job; it must not be exposed as an ordinary client delete.

## 7. Deliberately omitted entities and denormalisation

The model favours the smallest set of entities that still enforces the approved invariants. The following omissions are intentional, not oversights.

| Not modelled | Why it is unnecessary now | Revisit if |
|---|---|---|
| Separate `drivers` table | `driver_profiles.user_id` is a one-to-one extension of `users`; a separate identity would duplicate the same person and create synchronization risk. | Drivers need a genuinely separate identity or multiple profiles per user. |
| `passenger_profiles` | Passengers are `users`; the passenger relationship is a trip FK, not a profile. | Passenger-specific verified attributes or preferences enter scope. |
| `vehicle_assignments` history table | A trip stores its one assignment; assignment changes are prohibited after acceptance, and `audit_events` records the assignment event. | Multiple assignment attempts/reassignments become a product requirement. |
| `fare_quotes` or `rate_cards` | The agreed fare is a deliberate snapshot on the trip; the MVP excludes surge, tolls and post-trip adjustment (A1). | Pricing becomes a first-class, versioned workflow. |
| Separate `payment_attempts` table | `payments` already has attempt-level rows (`attempt_no`), which is the minimum needed for retries and one-success enforcement. | A payment aggregate needs its own lifecycle independent of attempts. |
| `trip_status_history` | `audit_events` stores actor, action, entity and before/after state. A second history table would duplicate the same facts. | Status history needs a different retention or high-volume query pattern than audit. |
| `trip_participants` | A trip has exactly one passenger and at most one driver; two columns plus checks are simpler than a participant join table. | Multi-passenger trips or shared rides enter scope. |
| Reusable `addresses` | Pickup/dropoff are trip-specific snapshots; an address book is not in the five actions. | Saved places or reusable addresses enter scope. |
| `reviews.driver_id` | The reviewed driver is exactly `trips.driver_id`; duplicating it would permit drift and add a redundant FK/index. | Reviews must snapshot a driver independently of later trip changes. |
| `trip_location_samples.driver_id` | The driver is derivable from the trip; adding it to every high-volume sample is unjustified denormalisation. | Samples must be attributable to a driver independent of trip assignment. |
| Status lookup tables | `CHECK` constraints give the same value set without joins and keep migrations explicit. | Statuses become admin-configurable data. |
| Review replies/moderation/ratings of passengers | Out of scope for R5; adding them would expand the product. | Review moderation becomes a requirement. |
| Driver presence/availability tables | Matching is first-valid-accept in the MVP (A13); no presence feed is required. | Dispatch/availability becomes a requirement. |
| Notification/outbox tables | Notifications are outside the five actions and need an integration design. | Asynchronous notifications enter scope. |

### 7.1 Justified denormalisation

Two copies are deliberate and bounded:

1. **Payment amount/currency/method.** Each payment attempt stores the trip's fare, currency and method. These are financial facts for that attempt, and the composite FK guarantees they equal the trip tuple. They are not a second source of truth; the trip remains the agreed-fare record.
2. **Audit before/after JSONB.** `audit_events` intentionally captures a point-in-time representation. It is evidence, not a normalized read model, and must not contain secrets or full payment credentials.

No other duplicate ownership or status columns are introduced. In particular, driver identity is not copied onto reviews or location samples.

## 8. Requirement traceability

### 8.1 Core actions

| Action | Entities used | Primary enforcement |
|---|---|---|
| **R1 - Request trip** | `users`, `trips`, `idempotency_keys`, `audit_events` | Passenger FK; positive fare and ISO currency; immutable fare/currency; one-active-passenger partial unique index; idempotency for retries. |
| **R2 - Accept trip** | `users`, `driver_profiles`, `vehicles`, `trips`, `idempotency_keys`, `audit_events` | Transactional status transition; approved profile/vehicle; ownership composite FK; active-driver/vehicle partial unique indexes; idempotency. |
| **R3 - Retrieve trip/progress** | `trips`, `users`, `driver_profiles`, `vehicles`, `trip_location_samples`, `payments`, `reviews` | Trip PK; participant FKs; latest-sample index; payment-history index; review uniqueness. Authorization is API-level. |
| **R4 - Complete trip and record payment** | `trips`, `payments`, `idempotency_keys`, `audit_events` | Completion transition; separate payment status; payment composite FK to fare/currency/method; one-success partial unique; provider-reference uniqueness. |
| **R5 - Review completed trip** | `trips`, `reviews`, `users`, `audit_events` | Completed-trip trigger; composite `(trip_id, passenger_id)` FK; unique `trip_id`; update/delete rejection. |

### 8.2 Business rules

| Rule | Schema/constraint mapping |
|---|---|
| **BR1** Exactly one passenger per trip | `trips.passenger_id NOT NULL` FK to `users(id)`. |
| **BR2** At most one driver/vehicle; both-or-neither; distinct passenger/driver | Single nullable `driver_id`/`vehicle_id`; both-or-neither check; `passenger_id <> driver_id`; composite ownership FK. |
| **BR3** One active trip per passenger | Partial unique `(passenger_id) WHERE status IN (active statuses)`. |
| **BR4** One active trip per driver | Partial unique `(driver_id) WHERE driver_id IS NOT NULL AND status IN (active statuses)`. |
| **BR5** One active trip per vehicle | Partial unique `(vehicle_id) WHERE vehicle_id IS NOT NULL AND status IN (active statuses)`. |
| **BR6** Only approved, eligible driver with owned approved vehicle accepts | `driver_profiles.status`, `vehicles.status`, ownership composite FK and active-trip indexes, applied inside the acceptance transaction. This is a documented transactional invariant; a single static FK cannot encode every predicate. |
| **BR7** Fare/currency fixed at request and preserved | Immutable `trips.fare_minor`, `trips.currency`, `requested_at` trigger; payment composite FK to the trip tuple. |
| **BR8** Integer minor units and ISO 4217; no floating point | `bigint` amounts; `varchar(3)` currency with `^[A-Z]{3}$`; no floating-point money columns. |
| **BR9** At most one successful collection; retries/callbacks safe | Partial unique `(trip_id) WHERE status='succeeded'`; unique provider reference; idempotency key unique tuple. |
| **BR10** Only the trip's passenger reviews; one review per completed trip | Composite `(trip_id, passenger_id)` FK; unique `trip_id`; completed-trip insert trigger. |
| **BR11** Reviews immutable | Update/delete-rejecting trigger. |
| **BR12** Explicit state machine; terminal states cannot reopen | Status `CHECK` plus Stage 3 transition trigger; partial indexes use the active status set. |
| **BR13** UUID is not authorization | No schema substitute; API ownership/assignment checks on every endpoint. UUID opacity alone grants nothing. |
| **BR14** Financial/audit history not casually deleted | No delete endpoints; restrictive FKs; append-only triggers; retention process deferred. |
| **BR15** Payment amount/currency equal trip fare/currency | Composite FK `(trip_id, amount_minor, currency, method)` -> `trips(id, fare_minor, currency, payment_method)`; method is also fixed. |
| **BR16** Assignment immutable after acceptance | Trigger permits only both-null to both-set; composite FK preserves ownership; no reassignment path. |
| **BR17** Completion and payment outcome are independent | Separate `trips.status` and `payments.status`; no FK or cascade from payment failure to trip status; completion does not require a successful payment row. |

### 8.3 Non-functional requirements

| NFR | Schema mapping |
|---|---|
| **NFR1** Data integrity | Primary/foreign keys, checks, partial unique indexes and documented triggers across all entities; section 5 is the enforcement map. |
| **NFR2** Authorization | `users`/`driver_profiles`/`trips` ownership relationships; API-level object authorization. No UUID-only access; no RLS assumed. |
| **NFR3** Financial correctness | `trips.fare_minor`/`currency`; `payments.amount_minor`/`currency`; immutable fare tuple; one-success partial unique; composite payment FK. |
| **NFR4** Auditability | `audit_events` actor/action/entity/timestamps/before-after, append-only trigger, entity/actor indexes. |
| **NFR5** Concurrency | Partial unique indexes for active trips and successful payment; acceptance/completion are transactional; row locks/conditional updates are required in Stage 3. |
| **NFR6** Performance | `trips(passenger_id, created_at DESC)`, `trips(driver_id, created_at DESC)`, partial requested-trip index, `trip_location_samples(trip_id, recorded_at DESC, id DESC)`, `payments(trip_id, created_at DESC)`. Additional indexes require plan evidence. |
| **NFR7** API consistency | `idempotency_keys` unique `(principal, operation, key)`, request fingerprint, stored response and expiry; UUID identifiers and UTC timestamps throughout. |
| **NFR8** Security/privacy | Field minimisation; location access by trip participants/admin; no credential columns; retention decisions remain explicit. |
| **NFR9** Testability/evidence | Deterministic schema supports the planned negative inserts and query plans; migrations/seed are Stage 3 deliverables and are not created here. |

### 8.4 Negative tests the model is designed to reject

These are the expected database-level failures for the Stage 5 evidence set. Exact SQL and screenshots are deferred.

| Attempt | Mechanism that should reject it |
|---|---|
| Second active trip for one passenger | Partial unique active-passenger index. |
| Second active acceptance for one driver | Partial unique active-driver index. |
| Same vehicle assigned to two active trips | Partial unique active-vehicle index. |
| Driver A assigned with driver B's vehicle | Composite `(driver_id, vehicle_id)` ownership FK. |
| Passenger and driver are the same user | `passenger_id <> driver_id` check. |
| Second review for one trip | Unique `reviews(trip_id)`. |
| Review written by a non-passenger | Composite `(trip_id, passenger_id)` FK. |
| Review of an incomplete/cancelled trip | `reviews_require_completed_trip` trigger. |
| Second successful payment for one trip | Partial unique successful-payment index. |
| Payment amount/currency/method differs from the trip | Payment composite FK to the trip tuple. |
| Fare/currency changed after request | Trip immutability trigger. |
| Driver/vehicle reassigned after acceptance | Trip assignment immutability trigger. |
| Forbidden status transition | Stage 3 transition trigger. |
| Unapproved driver accepts | Acceptance transaction checks profile/vehicle status and ownership. |

## 9. Decisions and open items

### 9.1 Choices adopted in this draft

The following choices are used throughout the model. They are not hidden requirements changes; the material ones are listed again with options in section 9.2 for explicit approval.

- Account role and driver capability are separate: `users.role` is only `customer` or `admin`; a driver is a customer with a `driver_profiles` row.
- A driver profile is a one-to-one extension of a user, with `driver_profiles.user_id` as PK/FK.
- Vehicle ownership and trip assignment are linked by a composite FK.
- Active-trip uniqueness is per passenger, per driver and per vehicle, using partial unique indexes.
- A trip has at most one driver and one vehicle, assigned together; the passenger and driver cannot be the same user.
- Reviews are keyed by trip, owned by the trip's passenger through a composite FK, and made valid only for a completed trip. The reviewed driver is derived from the trip.
- Fare and currency are immutable trip facts. Payment attempts carry the same tuple and are tied to it by a composite FK.
- Payment retries are new `payments` rows; at most one row per trip can be successful.
- Audit history is append-only and polymorphic; financial/audit rows are not deletable through ordinary application paths.
- Every entity has `created_at` and `updated_at`; immutable tables retain `updated_at` for uniformity but reject updates.

### 9.2 Open or schema-material decisions

These decisions need review before Stage 3. The recommendation is the default used in this draft; changing it may change the schema or behaviour.

| ID | Decision | Options and trade-offs | Recommended MVP default | Schema impact / approval |
|---|---|---|---|---|
| **D1** | Cross-capacity active trips (A12) | **A. Per-capacity** (current): a dual-capability user could be a passenger on one active trip and a driver on another. Literal reading of BR3/BR4; simpler and faster. **B. One active trip per user in any capacity**: matches physical reality, but needs a cross-table trigger with advisory locks or a participant table, and complicates concurrent acceptance. | **A. Per-capacity** for the MVP, because it preserves the approved Stage 1 rule; if “conflicting” is intended to include cross-capacity, choose B before Stage 3. | No table change for A; B adds a trigger/lock or a new participant structure. **Approval required.** |
| **D2** | Driver profile identity | **A. `user_id` as PK** (current): one identity, simple distinct/ownership checks, no extra ID. **B. Synthetic `driver_profile_id`**: permits multiple profiles per user or profile lifecycle independent of the account, at the cost of a second identifier and more joins. | **A. `user_id` as PK.** | Changes every driver FK and API identifier if B is chosen. **Approval required.** |
| **D3** | Payment representation | **A. One `payments` row per attempt** (current): minimal, directly supports retries, and one-success is a partial unique index. **B. `payments` aggregate + `payment_attempts`**: cleaner “current payment” object, but an extra entity and more joins. | **A. Attempt-level rows.** | Changes the payment table shape and constraints if B is chosen. **Approval required.** |
| **D4** | Review driver linkage | **A. Derive the driver from `trips.driver_id`** (current): normalized, no drift, immutable assignment makes it safe. **B. Store `reviews.driver_id`**: direct driver aggregates and a snapshot, but duplicates the assignment and needs a composite FK to prevent drift. | **A. Derive from the trip.** | B adds `reviews.driver_id` and a composite `(trip_id, driver_id)` FK. **Approval required.** |
| **D5** | User deletion and retention (A7) | **A. Soft delete + later anonymisation** (current `users.deleted_at`): preserves FKs/history, but keeps the email occupied and needs a controlled erasure process. **B. Hard delete**: simpler storage, but conflicts with financial/audit retention and requires cascade/anonymisation design. | **A. Soft delete; no hard delete in the MVP.** | `deleted_at`, email uniqueness and retention jobs depend on this. **Approval required.** |
| **D6** | Location retention and delete behaviour (A10) | **A. Time-based retention + `ON DELETE CASCADE`** (current): simple telemetry cleanup; a controlled trip deletion removes samples. **B. Restrict and delete explicitly**: safer ordering, more operational work. | **A. 30-day post-completion retention and cascade for telemetry only.** | FK behaviour and the retention job depend on this. **Approval required.** |
| **D7** | Payment method mutability | **A. Fixed at request** (current): supports the composite fare/currency/method FK and a single payment history. **B. Changeable before completion**: accommodates a passenger switching method, but needs a method-change audit and may split attempts/refunds. | **A. Fixed at request.** | B removes `trips.payment_method` from the composite FK and adds method-change rules. **Approval required.** |
| **D8** | Fare adjustments | **A. Fixed fare, no adjustments** (current): matches A1’s exclusion of surge, tolls and post-trip changes. **B. Add adjustments**: supports tolls/promotions/refunds, but requires a new financial entity, audit and reconciliation. | **A. Fixed fare for the MVP.** | B requires a `trip_fare_adjustments` (or fare-version) entity; the original snapshot must not be mutated. **Approval required if adjustments are in scope.** |
| **D9** | Authorization enforcement | **A. API-level ownership/assignment checks** (current): consistent with the OpenAPI contract and simpler DB roles. **B. PostgreSQL RLS**: defence in depth, but policy complexity and service-role bypass risks. | **A. API checks plus a least-privilege application role; no RLS in the MVP.** | No table change; B adds policies and session/role setup. **Approval required if RLS is expected.** |

### 9.3 Deferred to later stages

| Item | Deferred decision | Why it does not block this model |
|---|---|---|
| A1 pricing formula and rounding | Exact rate policy and rounding. | The trip stores the agreed integer minor-unit fare; no rate table is needed in the MVP. |
| A6 cancellation/expiry | Actors, reasons, TTL, fees, and the exact transition matrix. | Statuses and timestamps are reserved; Stage 3 owns the state machine. |
| A9 idempotency TTL | Exact expiry period. | `idempotency_keys.expires_at` and the cleanup index exist; the value is operational. |
| A10 sampling frequency/precision | How often samples are produced and exact retention. | The sample table and latest-sample index are defined; frequency is a client/API concern. |
| A11 authentication | Token issuance and identity provider. | No credential columns are stored; external auth is assumed. |
| A13 matching | Presence, proximity ranking or dispatch optimisation. | The model supports first-valid-accept; no presence table is introduced. |
| A14 display/retention details | Localisation and exact `deleted_at`/retention policy. | UTC `timestamptz` and the timestamp convention are defined; policy remains Stage 3. |

## 10. Consistency with Stage 1 and approval

### 10.1 Compliance with the Stage 1 baseline

No changes were made to `docs/requirements.md`. This stage created documentation only: no SQL migration, database table, seed data, application code, API endpoint or frontend file.

### 10.2 Refinements, not silent scope changes

The following are refinements of the Stage 1 traceability intent. None contradicts an approved requirement; each is flagged where it changes a modelling choice.

1. **Driver profile identity:** Stage 1 did not fix a separate driver-profile UUID. This draft uses `users.id` as the profile key (D2). This is a schema-material choice for approval.
2. **Payment granularity:** Stage 1 used `payments` as the payment entity and required retries/one success. This draft defines one row per attempt (D3), which makes BR9 directly enforceable.
3. **Review driver link:** The Stage 1 traceability matrix allowed a `reviews.driver_id` index “if a driver snapshot is stored.” This draft derives the driver from `trips.driver_id` and therefore does not add that column or index (D4). The composite passenger FK and completed-trip trigger remain.
4. **Location samples:** No `driver_id` is duplicated on samples; authorization derives the assigned driver from the trip. This is a normalization choice, consistent with BR13 and NFR8.
5. **Cross-capacity active trips:** A12 remains open. The base model enforces per-capacity rules and same-trip distinctness; it does not silently adopt the stricter per-user rule (D1).
6. **Retention/deletion:** A7, A9, A10 and A14 remain open. The draft adopts soft delete for users, restrictive FKs for financial/audit records, and a proposed telemetry retention/cascade (D5, D6).
7. **Timestamp convention:** Every entity has `created_at`/`updated_at`, including immutable and append-only records, as required. Immutable records reject updates rather than pretending `updated_at` is meaningful mutation metadata.

### 10.3 Inconsistencies found

**No material inconsistency with the approved Stage 1 requirements was found.** The only differences are the explicit refinements above:

- the optional `reviews.driver_id` from the provisional Stage 1 index list is intentionally absent;
- `payments` is now explicitly attempt-level rather than an unspecified aggregate;
- `driver_profiles` has a concrete `user_id` PK;
- cross-capacity enforcement remains the documented A12 open item rather than being silently tightened.

If any of these refinements is not acceptable, it should be changed in this document before Stage 3; the requirements document should not be edited to hide the difference.

### 10.4 Approval checklist

Please review and either approve or amend:

1. **D1:** keep per-capacity active-trip enforcement, or require one active trip per user across both capacities.
2. **D2:** keep `driver_profiles.user_id` as the PK, or introduce a synthetic driver-profile ID.
3. **D3:** keep one `payments` row per attempt, or split aggregate and attempts.
4. **D4:** keep the driver derived from the trip, or store `reviews.driver_id`.
5. **D5:** keep user soft delete with `deleted_at`, or choose a hard-delete/anonymisation model.
6. **D6:** keep telemetry cascade plus proposed 30-day retention, or restrict deletes to an explicit retention process.
7. **D7/D8:** keep payment method and fare fixed at request, with no post-trip adjustments.
8. **D9:** keep API-level authorization and no RLS for the MVP.

After approval, Stage 3 can translate this model into explicit SQL migrations and the state-machine specification. No implementation should begin before that approval.






