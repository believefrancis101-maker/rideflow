# RideFlow - Stage 3 Design Decisions

| Field | Value |
|---|---|
| Assessment | Task 3 - API Design and Data Modeling |
| Stage | 3 - Design Decisions and State Machines |
| Status | Draft for approval |
| Baselines | `docs/requirements.md` (Stage 1 - approved), `docs/data-model.md` (Stage 2), `docs/er-diagram.md` (Stage 2) |
| Companion documents | `docs/state-machines.md`, this document |
| Scope | Design documentation only. No SQL migrations, database tables, seed data, application code, API endpoints or frontend files. |

## 1. Purpose

This document records the design decisions adopted during Stage 3 of the RideFlow assessment, and the open items that remain outstanding.

Stage 3 translates the approved Stage 1 requirements baseline and the approved Stage 2 entity/ER design into an explicit design position, before any SQL implementation is written.

Stage 3 is a documentation and decision-record stage. It does not create implementation artefacts, and it does not modify the approved Stage 1 requirements.

## 2. Approved inputs

### 2.1 Stage 1 requirements baseline - `docs/requirements.md`

Approved. Binding source for: the five core actions (R1-R5 and sub-requirements), business rules (BR1-BR17), non-functional requirements (NFR1-NFR9), trip/payment/review/driver status vocabularies, MVP exclusions, conflicts (C1-C6), assumptions (A1-A14), traceability matrix, and verification plan.

### 2.2 Stage 2 data model - `docs/data-model.md`, `docs/er-diagram.md`

Delivered and approved following the Stage 2 read-only audit and the stakeholder decision approvals recorded in section 2.3.

### 2.3 Stage 3 decisions approved by the stakeholder

| Decision | Approved outcome |
|---|---|
| **D1** | Per-capacity active-trip limits; a dual-capability user may have one active trip in each capacity, but cannot be both passenger and driver on the same trip. |
| **D2** | `driver_profiles.user_id` is the primary key and references `users.id`. |
| **D3** | One payment row per attempt; retries create new attempt records. |
| **D4** | Reviewed driver is derived through the trip (`trips.driver_id`) rather than duplicating the driver ID in reviews. |
| **D5** | Soft-delete user accounts, with controlled anonymisation and retention policies documented separately; no invented legal retention periods. |
| **D6** | Time-based retention for driver location samples; retention mechanism documented and exact duration configurable pending a justified policy. |
| **D7** | Payment method is fixed at trip request time in the MVP. |
| **D8** | No post-request fare adjustments in the MVP. |
| **D9** | API-level authorization in the MVP; every data-access query must enforce ownership and authorization; UUIDs alone do not provide security. |
| **A1** | Deterministic fare formula using base fare, distance, duration and minimum fare; integer arithmetic and explicit rounding rule; example rates illustrative/configurable, not real market rates. |
| **A2** | MVP operating currency is NGN; explicit ISO currency code stored with every monetary amount; multi-currency change list documented. |
| **A12** | Approved per-capacity rule applied consistently to requirements, indexes and transaction/concurrency logic. |

## 3. Stage 3 design decisions

### DD-1 - Trip state machine: database-enforced transitions

The written model constrains `trips.status` to a CHECK-constrained value set (data-model.md, entity `trips`). Stage 3 design decision: a database trigger (to be expressed in the Stage 5 SQL) validates allowed state transitions, making the state machine database-enforced as a backstop to API-level enforcement.

The allowed transition design is specified in `docs/state-machines.md`.

### DD-2 - Payment state machine and retry semantics

The design keeps `payments.status` as `pending`, `succeeded` or `failed`, with a transition design that permits `pending -> succeeded` and `pending -> failed`, and treats `succeeded`/`failed` as terminal.

Retries do not mutate terminal attempts; they create new attempt records with an incremented `attempt_no` (D3), while idempotency (A9/D9 design) ensures replay safety.

### DD-3 - Driver approval and vehicle status transitions

Admin-driven status changes are designed as CHECK-constrained status values with operational transitions:

- `driver_profiles.status`: `pending -> approved`, `pending -> rejected`, `approved -> suspended`, `suspended -> approved`.
- `vehicles.status`: `pending -> approved`, `approved -> suspended`, `suspended -> approved`.

These transitions are operational (admin API) responsibilities with audit recording; status value sets are DB-enforced via CHECK constraints.

### DD-4 - Driver availability derivation

Driver availability is designed to be derived (no separate availability entity), consistent with the approved decision to avoid unnecessary entities and with BR6:

An eligible driver for a requested trip has: approved driver profile, approved owned vehicle that is not suspended, no active trip, and the trip is in `requested` status and accepting.

### DD-5 - Audit design

Append-only audit events are designed to cover trip lifecycle, assignment, fare, payment, review and eligibility/admin actions. Before/after JSONB captures relevant state; the audit table rejects update/delete.

### DD-6 - Timestamp and immutability conventions

Lifecycle timestamps (`requested_at`, `accepted_at`, `driver_arriving_at`, `started_at`, `completed_at`, `cancelled_at`, `expired_at`) are set with transitions; immutable fields are trigger-protected; every entity retains `created_at`/`updated_at` with the documented conventions.

### DD-7 - Deletion and retention design

No delete endpoints are designed for business records; restrictive foreign keys and append-only protection apply. User soft delete (D5) and time-based location retention (D6) are designed with configurable retention duration pending a justified policy.

### DD-8 - UUID identifier rationale

UUIDs are designed as opaque identifiers generated by `gen_random_uuid()`, consistent with BR13; UUIDs are not authorization and API-level ownership checks are mandatory (D9).

### DD-9 - Monetary representation

Design keeps integer minor units (`bigint`) with explicit ISO 4217 currency (`varchar(3)`), per BR8; MVP operating currency NGN (A2); fare formula and rounding per A1; final amount equals agreed fare; no floating point and no FX.

### DD-10 - Idempotency design

Design uses idempotency keys scoped to principal + operation + key, with SHA-256 request fingerprint and stored response, plus `expires_at` TTL design (A9). Idempotency lookup precedes current-state precondition checks so legitimate replays succeed (R1.6, R2.7, R4.6).

### DD-11 - Concurrency design

Design uses conditional status updates and partial unique indexes inside transactions to prevent double assignment/success, with losing concurrent callers receiving conflict outcomes (NFR5).

### DD-12 - Normalization and justified denormalizations

Design keeps the core model normalised and adopts exactly two justified denormalizations: (1) payment amount/currency/method snapshot on attempt rows, tied to the trip tuple via composite FK; (2) audit before/after JSONB capture. No other denormalizations are adopted.

## 4. Seven hard design questions addressed in Stage 3

1. **Double assignment prevention** - conditional updates + partial unique indexes + composite FK (DD-1, data-model invariants).
2. **Idempotency of unsafe operations** - idempotency design (DD-10).
3. **Fare snapshot and monetary integrity** - immutable fare tuple, integer minor units, composite FK, rounding (DD-9).
4. **Duplicate successful payment prevention** - partial unique success + provider reference uniqueness + retry semantics (DD-2).
5. **Review correctness** - composite FK + unique + completed-trip trigger + immutability (data-model).
6. **Trip state machine enforcement** - DB-enforced transition design (DD-1, state-machines).
7. **Audit/financial history integrity** - append-only design (DD-5, DD-7).

## 5. Remaining uncertainties after Stage 3 design

- A6: cancellation/expiry policy detail (actors, reasons, TTL, fees).
- A9: exact idempotency key TTL.
- A10: location sampling frequency/precision (retention configurable).
- A11: authentication mechanism.
- A14: exact timestamp policy.
- Retention periods / legal considerations (D5/D6; no invented periods).

## 6. Index Strategy Mapped to R1–R5

This section establishes the comprehensive index strategy for RideFlow, directly mapping every relevant proposed index to one or more of the five core actions (R1–R5). It reuses and formalises the index catalogue defined in `docs/data-model.md` and explicitly separates indexes required for database-enforced integrity and concurrency invariants from indexes designed for query and join performance.

### 6.1 Design principles and performance qualification

1. **No blanket indexing:** Indexes impose non-trivial write amplification, memory footprint (buffer pool churn), and WAL storage overhead. Only indexes directly supporting core actions R1–R5, foreign-key cascade/join performance, or database invariants are proposed.
2. **PostgreSQL foreign keys do not auto-index:** Creating a foreign key in PostgreSQL does not automatically create an index on the referencing foreign-key column(s). All foreign-key lookup paths that participate in joins, parent lookups, or cascading/restrictive integrity checks must have explicit supporting indexes where justified.
3. **Evidence-based performance claims:** Final latency and throughput verification (e.g., NFR6 read/write p95 budgets) cannot be proven by index declarations alone. Binding performance claims require empirical query execution plans (`EXPLAIN (ANALYZE, BUFFERS)`) during the database-evidence stage (Stage 5).

---

### 6.2 Detailed index mapping to core actions (R1–R5)

#### R1 — Passenger requests a trip (BR1, BR2, BR3, R1.1–R1.6, NFR6, NFR7)

| Table | Index columns / expression | Index type | Query / operation supported | Action(s) supported | Column order & predicate rationale | Integrity invariant vs Lookup performance |
|---|---|---|---|---|---|---|
| `trips` | `(id)` | Primary key (B-tree) | Single-trip row insertion; returning generated trip record by ID; subsequent detail fetches | R1, R2, R3, R4, R5 | Standard unique B-tree on synthetic UUID PK. | Both (Uniqueness integrity + PK point lookup) |
| `trips` | `(passenger_id) WHERE status IN ('requested', 'accepted', 'driver_arriving', 'in_progress')` | Partial unique | Pre-insert / insert enforcement of passenger single active trip constraint (BR3) | R1 | Single-column `passenger_id` filtered strictly to active trip statuses. Partial predicate keeps index cardinality minimal (only active trips, typically << 1% of total trip volume) while locking out concurrent requests for the same passenger. | Integrity / concurrency invariant |
| `idempotency_keys` | `(principal_user_id, operation, key)` | Composite unique | Idempotent request replay lookup and conflict detection for unsafe operations (e.g. `operation = 'trip.request'`) | R1 (also R2, R4) | Leading column `principal_user_id` scopes to authenticated caller; `operation` isolates the endpoint domain; `key` provides exact match. Enforces at-most-once execution under concurrency. | Integrity / concurrency invariant |
| `trips` | `(passenger_id, created_at DESC)` | Ordinary B-tree lookup | Fetching recent trip history for the requesting passenger or verifying past completed requests | R1, R3 | Leading `passenger_id` satisfies equality filter; trailing `created_at DESC` enables index scan for reverse-chronological sorting and pagination without an in-memory sort. | Lookup performance |

#### R2 — Eligible driver accepts a trip (BR4, BR5, BR6, BR7, BR8, BR16, R2.1–R2.7, NFR5, NFR6)

| Table | Index columns / expression | Index type | Query / operation supported | Action(s) supported | Column order & predicate rationale | Integrity invariant vs Lookup performance |
|---|---|---|---|---|---|---|
| `trips` | `(driver_id) WHERE driver_id IS NOT NULL AND status IN ('requested', 'accepted', 'driver_arriving', 'in_progress')` | Partial unique | Conditional trip assignment update; enforces that a driver cannot accept more than one active trip concurrently (BR4) | R2 | Null-guard (`driver_id IS NOT NULL`) ensures unassigned `requested` trips are excluded; active status predicate restricts entries strictly to in-flight trips. Prevents double-assignment races. | Integrity / concurrency invariant |
| `trips` | `(vehicle_id) WHERE vehicle_id IS NOT NULL AND status IN ('requested', 'accepted', 'driver_arriving', 'in_progress')` | Partial unique | Conditional trip assignment update; enforces that a vehicle cannot be assigned to more than one active trip concurrently (BR5) | R2 | Null-guard (`vehicle_id IS NOT NULL`) ensures unassigned trips are excluded; active status predicate restricts entries strictly to in-flight trips. Prevents double-booking a shared vehicle. | Integrity / concurrency invariant |
| `trips` | `(created_at ASC) WHERE status = 'requested'` | Partial B-tree | Driver queue read: listing available unassigned trip requests ordered by arrival time (FIFO) | R2 | Partial filter `status = 'requested'` excludes assigned and terminal trips, keeping index size small and fully cached in RAM. Key column `created_at ASC` delivers pre-sorted available requests without sorting overhead. | Lookup performance |
| `vehicles` | `(driver_id, status)` | Composite B-tree lookup | Pre-acceptance validation checking that the accepting driver owns at least one vehicle with `status = 'approved'` (BR6) | R2 | Leading `driver_id` satisfies the driver equality check; trailing `status` allows fast index-only filtering for `'approved'` status. | Lookup performance |
| `vehicles` | `(driver_id, id)` | Composite unique | Target of foreign key `trips(driver_id, vehicle_id) REFERENCES vehicles(driver_id, id)` | R2 | Enforces relational invariant that an assigned vehicle strictly belongs to the assigned driver. Supports composite FK reference checking on assignment update. | Integrity invariant |
| `driver_profiles` | `(status)` | Ordinary B-tree lookup | Driver eligibility verification (`status = 'approved'`) during acceptance or admin operational review | R2 | Equality lookup on driver profile status during trip acceptance. | Lookup performance |
| `idempotency_keys` | `(principal_user_id, operation, key)` | Composite unique | Idempotent replay for trip acceptance (`operation = 'trip.accept'`) preventing re-assignment side effects | R2 | Same key structure as R1; guarantees deterministic response on network retry. | Integrity / concurrency invariant |

#### R3 — Passenger or driver retrieves trip details and progress (R3.1–R3.7, NFR6, A10)

| Table | Index columns / expression | Index type | Query / operation supported | Action(s) supported | Column order & predicate rationale | Integrity invariant vs Lookup performance |
|---|---|---|---|---|---|---|
| `trips` | `(id)` | Primary key (B-tree) | Point lookup of complete trip aggregate by unique UUID | R3 (also R1, R2, R4, R5) | Direct clustered/unique B-tree lookup by trip ID (`trips.id = $1`). | Both (Integrity + Lookup performance) |
| `trip_location_samples` | `(trip_id, recorded_at DESC, id DESC)` | Composite B-tree lookup | Fetching the single most recent telemetry sample (`LIMIT 1`) or a bounded recent window of driver location updates | R3 | Leading `trip_id` binds to the active trip. `recorded_at DESC` delivers latest GPS coordinates first. Trailing `id DESC` serves as a deterministic tie-breaker for identical timestamps. | Lookup performance |
| `payments` | `(trip_id, created_at DESC)` | Composite B-tree lookup | Fetching payment attempt history and settlement status for the trip | R3, R4 | Leading `trip_id` satisfies FK join/filter; `created_at DESC` orders payment attempts chronologically without file-sort. | Lookup performance |
| `trips` | `(passenger_id, created_at DESC)` | Composite B-tree lookup | Participant trip list: passenger retrieving active or historical trips with pagination | R3, R1 | Leading `passenger_id` satisfies ownership/authorization predicate; `created_at DESC` provides standard timeline ordering. | Lookup performance |
| `trips` | `(driver_id, created_at DESC)` | Composite B-tree lookup | Participant trip list: assigned driver retrieving current assignment or completed trip history | R3, R2 | Leading `driver_id` satisfies driver authorization filter; `created_at DESC` provides reverse-chronological pagination. | Lookup performance |

#### R4 — Driver completes trip and records payment outcome (BR9, BR15, BR17, R4.1–R4.7, NFR5, NFR6)

| Table | Index columns / expression | Index type | Query / operation supported | Action(s) supported | Column order & predicate rationale | Integrity invariant vs Lookup performance |
|---|---|---|---|---|---|---|
| `payments` | `(trip_id) WHERE status = 'succeeded'` | Partial unique | Database enforcement of at-most-one successful payment settlement per trip (BR9) | R4 | Filtered specifically to `status = 'succeeded'`. Uniqueness on `trip_id` under this predicate strictly prevents race conditions from inserting or settling two successful payments (cash or electronic). | Integrity / concurrency invariant |
| `payments` | `(trip_id, attempt_no)` | Composite unique | Strict ordering and duplicate prevention of payment attempt sequence numbers | R4 | Scoped to `trip_id`; guarantees attempt sequence integrity and enables deterministic attempt numbering. | Integrity invariant |
| `trips` | `(id, fare_minor, currency, payment_method)` | Composite unique | Target of declarative composite FK from `payments(trip_id, amount_minor, currency, method)` (BR15) | R4 | Guarantees that every payment attempt recorded in `payments` strictly mirrors the immutable agreed fare, currency, and payment method captured at trip request time. | Integrity invariant |
| `payments` | `(provider_reference) WHERE provider_reference IS NOT NULL` | Partial unique | Provider callback deduplication; prevents duplicate processing of external gateway transaction references | R4 | Partial filter skips `NULL` values (e.g. cash payments or uninitiated transactions); enforces uniqueness across electronic payment processor IDs. | Integrity / concurrency invariant |
| `idempotency_keys` | `(principal_user_id, operation, key)` | Composite unique | Idempotent replay for trip completion / payment submission (`operation = 'trip.complete'` or `'payment.attempt'`) | R4 | Ensures network timeouts during completion/settlement return original response without duplicate payment initiation. | Integrity / concurrency invariant |

#### R5 — Passenger reviews their own completed trip (BR10, BR11, R5.1–R5.7)

| Table | Index columns / expression | Index type | Query / operation supported | Action(s) supported | Column order & predicate rationale | Integrity invariant vs Lookup performance |
|---|---|---|---|---|---|---|
| `reviews` | `(trip_id)` | Unique B-tree | Enforces at-most-one review per trip invariant (BR10) | R5 | Direct uniqueness on `trip_id` rejects any second review attempt for the same trip at the database level. Also optimizes parent FK lookup. | Integrity invariant |
| `trips` | `(id, passenger_id)` | Composite unique | Target of declarative composite FK from `reviews(trip_id, passenger_id)` (BR10) | R5 | Guarantees at the relational level that the submitting reviewer (`reviews.passenger_id`) is strictly the passenger who booked the trip (`trips.passenger_id`). | Integrity invariant |
| `reviews` | `(passenger_id, created_at DESC)` | Composite B-tree lookup | Passenger viewing their submitted review history | R5 | Leading `passenger_id` satisfies filter; `created_at DESC` sorts by most recent review. | Lookup performance |

---

### 6.3 Foreign-key-related lookup indexes

PostgreSQL enforces foreign keys by querying referenced and referencing tables, but it does **not** automatically index referencing foreign-key columns. Without dedicated indexes, table joins, parent row lookups, and parent updates/deletions can degenerate into full-table sequential scans.

The following explicit foreign-key indexes are established to support relational joins and integrity checks:

| Referencing Table & FK Column(s) | Referenced Table & PK Column(s) | Supporting Index | Justification & Operations Supported |
|---|---|---|---|
| `payments (trip_id)` | `trips (id)` | `payments(trip_id, created_at DESC)` | Covers the FK relationship. Supports joining payment attempts to trip aggregates (R3, R4) and prevents sequential scans during parent verification. |
| `reviews (trip_id, passenger_id)` | `trips (id, passenger_id)` | `reviews(trip_id)` (Unique) | Leading (and sole) column `trip_id` satisfies foreign-key lookups from `reviews` to `trips` (R5). |
| `trip_location_samples (trip_id)` | `trips (id)` | `trip_location_samples(trip_id, recorded_at DESC, id DESC)` | Leading column `trip_id` satisfies the foreign key. Essential for high-volume child row deletes when an `ON DELETE CASCADE` or retention purge occurs (R3). |
| `vehicles (driver_id)` | `driver_profiles (user_id)` | `vehicles(driver_id, status)` | Leading column `driver_id` satisfies FK lookup from vehicle to owning driver profile (R2). |
| `trips (passenger_id)` | `users (id)` | `trips(passenger_id, created_at DESC)` | Leading column `passenger_id` satisfies FK join from trips to passenger user account (R1, R3). |
| `trips (driver_id)` | `driver_profiles (user_id)` | `trips(driver_id, created_at DESC)` | Leading column `driver_id` satisfies FK join from trips to assigned driver profile (R2, R3). |
| `audit_events (actor_user_id)` | `users (id)` | `audit_events(actor_user_id, created_at DESC)` | Supports actor audit trail retrieval and satisfies FK relationship to `users(id)` for soft-deleted user checks (NFR4). |
| `idempotency_keys (principal_user_id)` | `users (id)` | Covered by unique `(principal_user_id, operation, key)` | Leading column `principal_user_id` satisfies foreign-key checks from idempotency table to `users(id)`. |

---

### 6.4 List-query indexes, filtering, sorting, and pagination

RideFlow avoids arbitrary open-ended filtering. All list queries exposed by the design are strictly scoped, paginated, and aligned to specific participant access patterns:

1. **Available trip queue (R2 - Drivers):**
   - Query: `SELECT * FROM trips WHERE status = 'requested' ORDER BY created_at ASC LIMIT $1`.
   - Index: Partial B-tree `trips(created_at ASC) WHERE status = 'requested'`.
   - Rationale: High efficiency, small index size. Completely eliminates sorting and table scanning for unassigned requests.
2. **Passenger trip history (R3/R1 - Passengers):**
   - Query: `SELECT * FROM trips WHERE passenger_id = $1 ORDER BY created_at DESC LIMIT $2 OFFSET $3` (or keyset pagination via `created_at < $cursor`).
   - Index: `trips(passenger_id, created_at DESC)`.
   - Rationale: Fully satisfies the equality filter on `passenger_id` and the sort on `created_at DESC`.
3. **Driver trip history (R3/R2 - Drivers):**
   - Query: `SELECT * FROM trips WHERE driver_id = $1 ORDER BY created_at DESC LIMIT $2 OFFSET $3`.
   - Index: `trips(driver_id, created_at DESC)`.
   - Rationale: Dedicated index for driver-assigned history without scanning other drivers' data.
4. **Driver location telemetry stream (R3 - Tracking):**
   - Query: `SELECT * FROM trip_location_samples WHERE trip_id = $1 ORDER BY recorded_at DESC, id DESC LIMIT 1`.
   - Index: `trip_location_samples(trip_id, recorded_at DESC, id DESC)`.
   - Rationale: Perfectly aligned with the latest telemetry fetch; guarantees deterministic `LIMIT 1` results via index scan.
5. **Passenger review list (R5 - Reviews):**
   - Query: `SELECT * FROM reviews WHERE passenger_id = $1 ORDER BY created_at DESC`.
   - Index: `reviews(passenger_id, created_at DESC)`.
   - Rationale: Supports passenger review history lookups.
6. **Entity audit history (NFR4 - Operational oversight):**
   - Query: `SELECT * FROM audit_events WHERE entity_type = $1 AND entity_id = $2 ORDER BY created_at DESC`.
   - Index: `audit_events(entity_type, entity_id, created_at DESC)`.
   - Rationale: Satisfies polymorphic entity audit lookups without full-table scans.

*No single index can support arbitrary multi-attribute filtering (e.g. filtering across dynamic date ranges, status filters, payment types, and geographical bounding boxes simultaneously). In accordance with Stage 3 principles, any further list-query index must be justified by demonstrable query plans.*

---

### 6.5 Categorization: Integrity/concurrency enforcement vs lookup performance

To maintain clear architectural boundaries, every index is categorised by its primary purpose:

| Primary Purpose | Index Identification | Rationale / Invariant Enforced |
|---|---|---|
| **Integrity & Concurrency Invariant** | `trips` partial unique `(passenger_id) WHERE status IN (active)` | Enforces BR3: prevents passenger from holding multiple concurrent active trips. |
| **Integrity & Concurrency Invariant** | `trips` partial unique `(driver_id) WHERE driver_id IS NOT NULL AND status IN (active)` | Enforces BR4: prevents driver double-assignment across concurrent requests. |
| **Integrity & Concurrency Invariant** | `trips` partial unique `(vehicle_id) WHERE vehicle_id IS NOT NULL AND status IN (active)` | Enforces BR5: prevents vehicle double-assignment across concurrent requests. |
| **Integrity & Concurrency Invariant** | `payments` partial unique `(trip_id) WHERE status = 'succeeded'` | Enforces BR9: guarantees at-most-one successful collection per trip. |
| **Integrity & Concurrency Invariant** | `payments` partial unique `(provider_reference) WHERE provider_reference IS NOT NULL` | Prevents duplicate processing of external payment gateway transactions. |
| **Integrity & Concurrency Invariant** | `idempotency_keys` composite unique `(principal_user_id, operation, key)` | Enforces at-most-once execution of mutating operations (R1, R2, R4). |
| **Integrity & Concurrency Invariant** | `reviews` unique `(trip_id)` | Enforces BR10: guarantees at-most-one review per completed trip. |
| **Integrity & Concurrency Invariant** | `payments` composite unique `(trip_id, attempt_no)` | Prevents collision of payment attempt sequence numbers. |
| **Integrity & Concurrency Invariant** | `trips` composite unique `(id, passenger_id)` | Relational target for composite FK enforcing reviewer ownership (BR10). |
| **Integrity & Concurrency Invariant** | `trips` composite unique `(id, fare_minor, currency, payment_method)` | Relational target for composite FK enforcing fare/payment snapshot preservation (BR15). |
| **Integrity & Concurrency Invariant** | `vehicles` composite unique `(driver_id, id)` | Relational target for composite FK enforcing driver vehicle ownership (BR6). |
| **Integrity & Concurrency Invariant** | `users` unique `(email)` | Enforces account email uniqueness. |
| **Integrity & Concurrency Invariant** | `vehicles` unique `(license_plate)` | Enforces vehicle license plate uniqueness. |
| **Lookup Performance** | `trips` partial B-tree `(created_at ASC) WHERE status = 'requested'` | Accelerates FIFO available-trip queue reads for drivers (R2). |
| **Lookup Performance** | `trip_location_samples (trip_id, recorded_at DESC, id DESC)` | Accelerates latest telemetry fetch and history reads (R3). |
| **Lookup Performance** | `trips (passenger_id, created_at DESC)` | Accelerates passenger trip history and status lookups (R1, R3). |
| **Lookup Performance** | `trips (driver_id, created_at DESC)` | Accelerates driver trip history and status lookups (R2, R3). |
| **Lookup Performance** | `vehicles (driver_id, status)` | Accelerates driver vehicle eligibility checks (R2). |
| **Lookup Performance** | `driver_profiles (status)` | Accelerates driver eligibility status verification (R2). |
| **Lookup Performance** | `payments (trip_id, created_at DESC)` | Accelerates trip payment history list reads and joins (R3, R4). |
| **Lookup Performance** | `reviews (passenger_id, created_at DESC)` | Accelerates passenger review history list reads (R5). |
| **Lookup Performance** | `audit_events (entity_type, entity_id, created_at DESC)` | Accelerates entity-specific audit trail lookups (NFR4). |
| **Lookup Performance** | `audit_events (actor_user_id, created_at DESC)` | Accelerates actor audit trail lookups (NFR4). |
| **Lookup Performance** | `idempotency_keys (expires_at)` | Accelerates background TTL pruning of expired idempotency keys (A9). |
| **Both (Integrity + Lookup)** | `users (id)`, `driver_profiles (user_id)`, `vehicles (id)`, `trips (id)`, `payments (id)`, `reviews (id)`, `trip_location_samples (id)`, `audit_events (id)`, `idempotency_keys (id)` | Primary keys: enforce entity uniqueness while providing fast point lookups by ID. |

---

### 6.6 Queries for which no dedicated index is proposed

In adherence to the anti-blanket-indexing policy, specific query categories are intentionally not provided with dedicated indexes in the MVP:

1. **Geospatial / Proximity queries (e.g. PostGIS `ST_DWithin` on driver coordinates):**
   - *Rationale:* Geographically matched dispatch is explicitly out of scope for the MVP (Assumption A13). Trip matching is accomplished via the simple FIFO available-request queue. Adding spatial indexes (e.g. GiST on coordinates) is unjustified at this stage.
2. **Arbitrary status-wide scans across historical trips (e.g. `WHERE status = 'completed'` or `'cancelled'`):**
   - *Rationale:* There are no operational queries in R1–R5 requiring full-table scans across historical terminal statuses. Participant reads are strictly bounded by `passenger_id` or `driver_id`. System-wide analytics belong to offline reporting, not OLTP indexes.
3. **Dedicated driver review index on `reviews (driver_id)`:**
   - *Rationale:* Reviews deliberately do not store `driver_id` (Decision D4); driver identity is derived via `trips.driver_id`. Calculating aggregate driver ratings joins `trips` via `trips.id` and uses `trips(driver_id, created_at DESC)`.
4. **General-purpose search on user names, phone numbers, or vehicle makes/models:**
   - *Rationale:* These attributes are not used in R1–R5 transaction critical paths. Text search indexes (e.g. GIN/trigram) would incur substantial write overhead without supporting any core requirement.
5. **Multi-attribute audit filtering combinations:**
   - *Rationale:* `audit_events` is append-only. The two established B-tree indexes (`entity_type, entity_id, created_at DESC` and `actor_user_id, created_at DESC`) satisfy targeted investigation without indexing every metadata key.

---

### 6.7 Storage overhead, write amplification, and validation path

1. **Storage and write overhead:**
   - Every secondary index requires B-tree rebalancing, WAL logging, and dirty buffer management on `INSERT` and `UPDATE`.
   - Partial indexes (`trips` active trip partial uniques, `trips` requested queue, `payments` succeeded partial unique) drastically limit this overhead by containing entries only for current in-flight records. Once a trip reaches terminal status (`completed`, `cancelled`, `expired`), it is automatically pruned from the active-trip partial indexes.
2. **Validation requirement in Stage 5:**
   - Documented index definitions are structural designs. Validating that PostgreSQL's query planner selects these indexes (rather than opting for bitmap index scans or sequential scans) requires synthetic load, realistic table statistics (`ANALYZE`), and explicit `EXPLAIN (ANALYZE, BUFFERS)` execution plans in Stage 5.

## 7. Stage 3 completion record

Stage 3 design documentation is complete: this file and `docs/state-machines.md` were created. No SQL migrations, tables, seed data, application code, API endpoints or frontend files were created. The approved Stage 1 requirements remain intact. Stage 3 awaits stakeholder review before Stage 4.
