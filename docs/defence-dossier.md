# RideFlow - Stage 6: Defence Dossier
## Rigorous Technical Justifications for Assessment Review

This dossier provides exhaustive, evidence-backed answers to the four mandatory technical defence questions outlined in the Task 3 assessment brief. Every architectural claim is grounded in the active PostgreSQL 16 schema, verified migration line numbers, and empirical test results produced in Stage 5B.

---

### Question 1: Show me a fact that lives in two places and defend it.

#### 1. The Fact and Its Exact Repository Locations
In RideFlow, the primary deliberate denormalisation where an operational and financial fact lives in two distinct database tables is the **agreed trip fare tuple**:
* **Location 1 (`trips` table)**: [`database/migrations/002_trips_and_telemetry.sql:21-23`](file:///c:/Users/USER/Desktop/rideflow/database/migrations/002_trips_and_telemetry.sql#L21-L23)
  * `fare_minor` (`BIGINT NOT NULL CHECK (fare_minor > 0)`)
  * `currency` (`VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$')`)
  * `payment_method` (`TEXT NOT NULL CHECK (payment_method IN ('cash', 'electronic'))`)
* **Location 2 (`payments` table)**: [`database/migrations/003_payments_reviews_audit_idempotency.sql:20-23`](file:///c:/Users/USER/Desktop/rideflow/database/migrations/003_payments_reviews_audit_idempotency.sql#L20-L23)
  * `amount_minor` (`BIGINT NOT NULL CHECK (amount_minor > 0)`)
  * `currency` (`VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$')`)
  * `method` (`TEXT NOT NULL CHECK (method IN ('cash', 'electronic'))`)

Additionally, a point-in-time snapshot of this fact lives in the audit log:
* **Location 3 (`audit_events` table)**: [`database/migrations/003_payments_reviews_audit_idempotency.sql:64`](file:///c:/Users/USER/Desktop/rideflow/database/migrations/003_payments_reviews_audit_idempotency.sql#L64)
  * Recorded within `after_data` JSONB at event time (e.g. `{"status":"requested","fare_minor":550000,"currency":"NGN","payment_method":"cash"}`). Note that `audit_events` snapshots domain state payloads, but deliberately does not denormalise human names (relying on `actor_user_id` FK).

#### 2. The Architectural Defence
In a purely normalised textbook model, one might argue that `payments` should only store a `trip_id` foreign key, retrieving the expected monetary charge by joining against `trips.fare_minor`. RideFlow deliberately rejects pure normalisation here for two critical engineering reasons:

1. **Decoupling Booking Contracts from Financial Settlement Lifecycle**:
   * `trips` models the *operational ride contract* agreed upon between the passenger and platform at booking time (`requested_at`).
   * `payments` models individual *monetary transaction attempts* submitted to banking gateways or settled in cash with drivers.
   * A trip can have multiple payment attempts (e.g., attempt 1 fails due to gateway timeout `PROVIDER_TIMEOUT`, and attempt 2 succeeds or is retried). Financial accounting, PCI-DSS compliance, and tax reconciliation require each attempt ledger row to be an immutable record of the exact currency, amount, and tender method submitted to the external payment processor.

2. **Declarative Database-Enforced Integrity (No Data Drift)**:
   * The fundamental risk of denormalisation is data divergence (where a payment attempt charges a different amount or currency than what was agreed on the trip).
   * Rather than relying on fragile application-layer synchronization, RideFlow enforces exact equality declaratively at the PostgreSQL catalog level using a **composite foreign key**:
     ```sql
     -- In trips (002_trips_and_telemetry.sql:103)
     CONSTRAINT trips_id_fare_currency_method_unique UNIQUE (id, fare_minor, currency, payment_method)

     -- In payments (003_payments_reviews_audit_idempotency.sql:27-28)
     CONSTRAINT payments_trip_fare_currency_method_fkey FOREIGN KEY (trip_id, amount_minor, currency, method)
         REFERENCES trips(id, fare_minor, currency, payment_method) ON DELETE RESTRICT
     ```
   * Furthermore, the trip's agreed fare tuple is protected against post-creation tampering by a PL/pgSQL immutability trigger in [`database/migrations/004_indexes_and_triggers.sql:183-191`](file:///c:/Users/USER/Desktop/rideflow/database/migrations/004_indexes_and_triggers.sql#L183-L191) (`fn_trips_immutability()`), which raises an exception with SQLSTATE `23514` if an update attempts to alter `fare_minor`, `currency`, or `payment_method`.

#### 3. Trade-offs Incurred
* **Storage Overhead**: An extra 16 bytes per payment attempt row (`BIGINT` + `VARCHAR(3)` + `TEXT`). In modern storage terms, 10 million payment attempts require ~160 MB of additional disk space—a negligible cost for financial ledger independence.
* **Write Amplification**: PostgreSQL must validate the composite foreign key index on every payment attempt insert.

#### 4. Anticipated Defence Counter-Questions
* *Examiner*: "What happens if a passenger disputes a ride and customer support issues a 20% discount after trip completion?"
* *Candidate Defense*: "In RideFlow's architecture, customer support does not alter the historical `trips.fare_minor` or the settled `payments` row. Doing so would falsify financial history and invalidate signed payment gateway settlements. Post-trip adjustments must be handled via a distinct credit note, refund ledger entity, or promotional credit balance, preserving the immutable record of the original ride and transaction."

---

### Question 2: A rider requests a second trip while one is in progress. Which line in your schema stops it?

#### 1. The Exact Line in the Schema
The primary database constraint that stops this is the **partial unique index** defined on **lines 11–13** of [`database/migrations/004_indexes_and_triggers.sql`](file:///c:/Users/USER/Desktop/rideflow/database/migrations/004_indexes_and_triggers.sql#L11-L13):

```sql
CREATE UNIQUE INDEX trips_active_passenger_idx
    ON trips(passenger_id)
    WHERE status IN ('requested', 'accepted', 'driver_arriving', 'in_progress');
```

#### 2. How the Enforcement Mechanism Works
* **Predicate Definition**: The index indexes only trips where `status IN ('requested', 'accepted', 'driver_arriving', 'in_progress')`.
* **Lock-Free Concurrency**: When a rider submits a new ride request via `POST /v1/trips` (Action R1), PostgreSQL checks the index tree for the tuple `(passenger_id)`.
* **Immediate Collision**: If the passenger already has an existing trip record in any active status (e.g., `in_progress`), the B-tree entry is already present. The engine immediately rejects the insert with `SQLSTATE 23505` (`unique_violation`).
* **Automatic Eviction**: The moment the active trip transitions to a terminal status (`completed`, `cancelled`, or `expired`), it no longer satisfies the index predicate `WHERE status IN (...)`. The slot is released automatically without requiring row deletions or tombstone flags.

#### 3. Supporting Guardrails
1. **Pre-insert Role Check**: [`database/migrations/004_indexes_and_triggers.sql:156-174`](file:///c:/Users/USER/Desktop/rideflow/database/migrations/004_indexes_and_triggers.sql#L156-L174) (`fn_trips_passenger_must_be_active_customer()`) verifies that `passenger_id` references an account with `role = 'customer'` and `status = 'active'`.
2. **Status Vocabulary Guard**: [`database/migrations/002_trips_and_telemetry.sql:12-14`](file:///c:/Users/USER/Desktop/rideflow/database/migrations/002_trips_and_telemetry.sql#L12-L14) ensures `status` is strictly one of the 7 valid domain statuses.

#### 4. Empirical Test Verification
This exact failure mode is proven by Negative Test 1 in [`database/tests/invalid_insert_1_passenger.sql`](file:///c:/Users/USER/Desktop/rideflow/database/tests/invalid_insert_1_passenger.sql) and recorded in live evidence [`evidence/07_rejected_insert_1_passenger.txt:25-30`](file:///c:/Users/USER/Desktop/rideflow/evidence/07_rejected_insert_1_passenger.txt#L25-L30):
```text
ERROR:  23505: duplicate key value violates unique constraint "trips_active_passenger_idx"
DETAIL:  Key (passenger_id)=(018d3f62-4401-7b3e-8c42-5f69a1e09100) already exists.
CONSTRAINT NAME:  trips_active_passenger_idx
```

#### 5. Anticipated Defence Counter-Questions
* *Examiner*: "Why use a partial unique index instead of an `EXCLUDE USING gist` constraint or an application-layer `SELECT ... FOR UPDATE` check?"
* *Candidate Defense*: "An application-layer check (`SELECT COUNT(*) ... WHERE status IN (...)`) is susceptible to race conditions under concurrent requests unless wrapped in restrictive `SERIALIZABLE` transactions or explicit table locks. A partial unique index guarantees sub-millisecond atomic enforcement directly in the B-tree engine. Furthermore, because active trips represent less than 0.1% of total historical trips in a production ride-hailing database, the partial index remains tiny and fits permanently in RAM, avoiding the indexing overhead of completed historical trips."

---

### Question 3: Why does the trip record store the fare rather than looking it up from the driver's current rate?

#### 1. Exact Repository Locations
* Schema definition: [`database/migrations/002_trips_and_telemetry.sql:21-22`](file:///c:/Users/USER/Desktop/rideflow/database/migrations/002_trips_and_telemetry.sql#L21-L22) (`fare_minor BIGINT NOT NULL CHECK (fare_minor > 0)` and `currency VARCHAR(3)`).
* Immutability enforcement: [`database/migrations/004_indexes_and_triggers.sql:183-185`](file:///c:/Users/USER/Desktop/rideflow/database/migrations/004_indexes_and_triggers.sql#L183-L185).

#### 2. The Architectural Defence
Looking up the fare dynamically from the driver's rate or a pricing service is a severe anti-pattern in on-demand transportation architecture:

1. **Pre-Ride Contractual Certainty**:
   * In modern ride-hailing, the platform presents an upfront or guaranteed fare snapshot to the passenger before they confirm the booking (Business Rule BR1).
   * Once requested, this agreed fare constitutes a legally binding contract between rider, platform, and driver.
2. **Preventing Tariff Drift During Execution**:
   * A trip across a metropolitan area such as Lagos can take anywhere from 30 minutes to 3 hours due to traffic congestion.
   * If the driver updates their vehicle tier, tariff profile, or hourly rate while in transit, or if the platform's real-time surge algorithm drops or spikes, dynamic rate lookup would cause the customer's final charge to fluctuate uncontrollably upon arrival.
3. **Decoupling from Driver Assignment**:
   * When a trip is created in Action R1 (`status = 'requested'`), **no driver is assigned yet** (`trips.driver_id IS NULL`). Looking up a fare from the driver's rate at booking time is impossible because the driver is unknown.
4. **Preserving Promotional and Dynamic Pricing Context**:
   * Upfront fares incorporate market-wide supply/demand surge multipliers, base fees, distance projections, and passenger promotional coupons at `requested_at`.
   * Storing `fare_minor` directly on `trips` captures this holistic financial outcome permanently, providing a reproducible baseline for accounting and driver payout splitting.

#### 3. Anticipated Defence Counter-Questions
* *Examiner*: "If fare calculation changes in the future (e.g. meter-based billing for detours), does this design break?"
* *Candidate Defense*: "No. Storing `fare_minor` on `trips` captures the baseline contract. As noted in Stage 1 Assumption A8 and Stage 3 DD-8, meter-based deviations or wait-time fees can be modeled either as separate operational adjustments or additional charge line items. The base agreed snapshot remains fixed and audit-traceable."

---

### Question 4: At what user count do you switch this endpoint to GraphQL, and what specifically would trigger it?

#### 1. Why User Count Alone Is an Ungrounded Metric
* In distributed systems architecture, user count (e.g. "switch at 100,000 users") is an **arbitrary vanity threshold**.
* A platform with 1,000,000 uniform mobile clients executing identical screens receives zero architectural benefit from GraphQL; in fact, it suffers from reduced HTTP caching and query complexity overhead.
* Conversely, a platform with only 5,000 users spanning smartwatches, mobile apps, fleet management dashboards, and public developer APIs may legitimately need a flexible query layer.
* Therefore, the evaluation for adopting GraphQL on the trip progress endpoint (`GET /v1/trips/{id}`) must be framed as **measurable operational hypotheses and architectural triggers**.

#### 2. The Measurable Trigger Hypotheses (To Be Empirically Validated)

| Trigger Hypothesis | Metric / Evaluation Boundary | Architectural Justification |
|---|---|---|
| **Hypothesis 1: Cellular Bandwidth & Payload Waste Threshold** | Cellular network telemetry demonstrates that **p95 payload discard rate exceeds 70%** and mobile p95 latency exceeds **800ms** on degraded networks. | As modeled in [`docs/api-design.md:518-598`](file:///c:/Users/USER/Desktop/rideflow/docs/api-design.md#L518-L598), the full REST trip entity is ~1,450 bytes, whereas an active trip status widget requires only ~210 bytes (status, driver name, plate, coordinates). If client telemetry reveals network bottlenecks due to over-fetching, sparse fieldset REST queries (`?fields=...`) or GraphQL become justified. |
| **Hypothesis 2: Client View Divergence Threshold** | The client ecosystem fragments into **≥ 4 distinct production client form factors** with divergent field consumption patterns. | When the platform supports simultaneously: (a) Passenger iOS/Android, (b) Driver Navigation HUD, (c) WearOS/watchOS complication widget, and (d) Enterprise Operations Dispatcher Console. At this point, fixed REST DTOs cause excessive bespoke endpoints (`/card-summary`, `/brief`, `/hud-details`), leading to Backend-for-Frontend (BFF) sprawl. |
| **Hypothesis 3: Backend Domain Federation Threshold** | The backend architecture transitions from a modular monolith to **≥ 5 distributed domain microservices** (e.g. Dispatch, Telemetry Ingestion, Dynamic Pricing, Driver Compliance, Billing). | At this scale (~50,000+ daily concurrent rides), a federated GraphQL gateway (e.g. Apollo Router / Federation v2) allows the trip aggregate to be stitched across microservices without forcing the mobile client to orchestrate 4 sequential REST calls. |

#### 3. Why REST Remains Superior for the Current MVP
As approved in [`docs/api-design.md:600-607`](file:///c:/Users/USER/Desktop/rideflow/docs/api-design.md#L600-L607):
1. **Broken HTTP Caching**: GraphQL routes all operations over HTTP `POST` to a single `/graphql` endpoint, bypassing intermediate CDN and gateway caches that accelerate REST `GET` requests.
2. **Object-Level Authorization Attack Surface**: GraphQL allows arbitrary recursive nesting. In ride-hailing, verifying that the authenticated caller (`jwt.sub`) has permission to view the passenger, driver, vehicle, and real-time GPS coordinates requires complex field-level resolvers, increasing the risk of Broken Object Level Authorization (BOLA).
3. **Idempotency Simplicity**: Standard REST maps naturally to HTTP verbs and standard `Idempotency-Key` tracking headers on `POST /v1/trips/{id}/accept` and `/complete`.
