# RideFlow - Requirements and Traceability

| Field | Value |
|---|---|
| Assessment | Task 3 - API Design and Data Modeling |
| Stage | 1 - Requirements and Traceability |
| Status | Draft for approval |
| Product | RideFlow (fictional ride-hailing platform) |
| Scope | API/data-model design and PostgreSQL proof only |
| Authoritative inputs | Task 3 brief, approved product scope, Stage 0 inspection report |
| Last updated | 2026-10-23 |

This document is the requirements baseline for later stages. Every entity, constraint, index, API endpoint and piece of evidence must trace back to a requirement or business rule below. Entity and endpoint names are provisional until Stages 2 and 4, but the traced intent is binding.

Sections 1-5 define the requirements baseline. Sections 6-8 provide the supporting assumptions, traceability matrix and verification plan; they are deliberately kept separate so the requirements page can be read without the matrix.

## 1. Product overview and business purpose

RideFlow is a fictional ride-hailing marketplace. Passengers request point-to-point trips, eligible drivers accept them with an approved vehicle, both parties can retrieve current trip progress, the assigned driver completes the trip, the system records the payment outcome, and the passenger may review the completed trip.

The business purpose is to provide a trustworthy ride-hailing workflow in which:

- a passenger can obtain a clear, agreed fare before committing to a trip;
- an eligible driver can be matched to exactly one active trip without double assignment;
- both parties can see reliable trip status and progress;
- cash and electronic payment outcomes are recorded without duplicate successful collection;
- completed trips can be reviewed by the passenger who took them; and
- trip, financial and eligibility changes remain auditable.

The MVP is a design and database-proof assessment. It includes a complete API contract and a PostgreSQL schema that enforces the model. It does **not** include a user-facing application, frontend, production API server, payment gateway integration, dispatch engine, map provider or background job runner.

The five core actions are:

| ID | Core action |
|---|---|
| R1 | Passenger requests a trip. |
| R2 | An eligible driver accepts a trip. |
| R3 | Passenger or driver retrieves current trip details and progress. |
| R4 | Driver completes the trip and the system records the applicable payment outcome. |
| R5 | Passenger reviews their own completed trip. |

Success means these five actions are fully specified and testable, the required invariants are enforceable in PostgreSQL, and later design decisions can be traced to this baseline.

## 2. Users, responsibilities and permissions

### 2.1 Role vocabulary

The role model is deliberately split into two concepts:

| Concept | Representation | Meaning |
|---|---|---|
| Account role | `users.role` = `customer` or `admin` | Determines the account's platform-level privileges. |
| Driver capability | A one-to-one `driver_profiles` record linked to a user | Determines whether the user may act as a driver. Driver is not a value of `users.role`. |

A `customer` is a normal human account. A customer may act as a passenger. A customer who also has an **approved** driver profile may act as a driver. The same person may therefore be both a passenger and a driver, but not in both capacities on the same trip.

An `admin` is an oversight account. Admin privileges are limited to driver/vehicle eligibility management and read-only operational/audit access. An admin does **not** automatically gain driver eligibility, and admin accounts do not act as passengers or drivers, or create trips, payments or reviews in the MVP.

A `driver_profile.status` of `approved` is necessary but not sufficient to accept a trip. The driver must also have an approved, non-suspended vehicle, must not already have an active trip, and must be accepting a trip that is still available. These conditions are defined in BR6.

A system actor is not a human user. It applies timestamps, expiry, payment outcomes and audit events, and is recorded as `system` in audit history.

### 2.2 Responsibilities

| Principal | Responsibilities | Explicitly not permitted |
|---|---|---|
| Passenger (customer) | Request a trip, select cash or electronic payment, view own trip and progress, view own payment outcome, review own completed trip. | Accept or complete a trip, view another passenger's trip, create a review for another passenger's trip. |
| Driver (customer with approved driver profile) | View available requested trips, accept one eligible trip with an approved vehicle, append location samples while assigned, view assigned trip/progress, mark arrival/start, complete the trip, record cash collection, read the review for the assigned trip. | Accept without eligibility, hold more than one active trip, view unassigned passenger details, review a trip as the driver, edit the passenger's review. |
| Admin | Approve, suspend or reject driver profiles and vehicles; read trips, payments, reviews and audit events for support and investigation. | Impersonate a user, create or alter trips, create or alter payments, write reviews, delete financial or audit history. |
| System | Expire unaccepted requests, close or settle payment attempts, write timestamps and audit events. | Bypass state-machine or financial invariants. |

### 2.3 Permission matrix

| Capability | Passenger (customer) | Driver (approved profile) | Admin |
|---|---|---|---|
| Request a trip | Own account only | Own account only, in passenger capacity | No |
| View available requests | No | Yes, for eligible requested trips | Read-only |
| Accept a trip | No | Eligible trips only | No |
| View trip details/progress | Own trip only | Assigned trip only | Read-only, all trips |
| Append location samples | No | Assigned active trip only | No |
| Complete a trip | No | Assigned trip only | No |
| Record/view payment outcome | View own trip's outcome; select method at request | Record cash outcome for assigned trip | Read-only |
| Review a completed trip | Own completed trip only | No; may read the review for an assigned trip | Read-only |
| Manage driver/vehicle eligibility | No | No | Yes |
| View audit history | No | No | Yes |

### 2.4 Driver eligibility

A driver is eligible to accept a specific trip only when all of the following are true:

1. The account is active.
2. The driver profile status is `approved`.
3. The selected vehicle belongs to that driver and has status `approved`.
4. The driver has no active trip in driver capacity.
5. The vehicle has no active trip.
6. The trip is in `requested` status and the passenger is not the same user as the driver.

Eligibility is checked transactionally at acceptance. A later suspension blocks new accepts but does not silently reassign an active trip; that operational exception is handled through cancellation/admin intervention in Stage 3.

## 3. The five core actions

Each action below is a complete business workflow. The functional requirements under each action are its testable acceptance criteria; they inherit the parent requirement ID for traceability. Supporting lifecycle operations that are necessary but are not one of the five core actions are listed in section 3.6.

### 3.1 R1 - Passenger requests a trip

**Actor:** An authenticated customer acting as a passenger.

**Preconditions:** The account is active; the passenger has no active trip; pickup and dropoff are valid; the payment method is `cash` or `electronic`; the trip currency is supported; the system can calculate a fare.

**Workflow:**

1. The passenger submits pickup, dropoff, payment method and an idempotency key.
2. The system authenticates the caller, authorises the passenger and validates the request.
3. The system checks that the passenger has no active trip.
4. The system calculates a server-side fare, rounds it to integer minor units and attaches an ISO 4217 currency code.
5. In one transaction, the system creates a trip in `requested` status with the passenger, route, agreed fare, currency, payment method and `requested_at`; it writes an audit event and records the idempotency result.
6. The system returns the created trip. No driver or vehicle is assigned yet.

**Postcondition:** Exactly one trip exists for the request, in `requested` status, with an immutable fare and currency snapshot.

**Failure handling:** Unauthenticated requests are rejected; an active-trip conflict returns a defined conflict response; invalid or unsupported input returns a validation error; a repeated request with the same idempotency key returns the original result rather than creating another trip.

**Functional requirements:**

- **R1.1** Only an authenticated customer may request a trip, and only for their own passenger identity.
- **R1.2** A passenger with any active trip must be rejected.
- **R1.3** Pickup, dropoff, payment method and currency must be validated before any write.
- **R1.4** The fare must be calculated server-side, stored as integer minor units with an ISO 4217 currency, and treated as the agreed fare. Client-supplied amounts must not override it.
- **R1.5** The trip must be created in `requested` status with no driver or vehicle assigned, and the creation must be audited.
- **R1.6** The request must be idempotent: an identical retry with the same principal, operation and key must return the original result, not create a second trip. The idempotency lookup occurs before the active-trip check so a legitimate replay is not mistaken for a new request.
- **R1.7** The response must expose the trip identifier, status, agreed fare/currency and request timestamp; it must not expose another passenger's data.

**Verification intent:** API contract tests; duplicate-active-trip negative test; idempotency replay test; database rejection of a second active trip for the same passenger; fare/currency snapshot check.

### 3.2 R2 - Eligible driver accepts a trip

**Actor:** An authenticated customer with an approved driver profile, acting in driver capacity.

**Preconditions:** The trip is `requested`; the driver profile is `approved`; the selected vehicle is owned by the driver, `approved` and not on another active trip; the driver has no active trip; the passenger and driver are distinct users; the request has not expired.

**Workflow:**

1. The driver submits an acceptance for a specific trip and vehicle, with an idempotency key.
2. The system authenticates the caller and verifies the driver profile and vehicle ownership.
3. In one transaction, the system attempts a conditional update from `requested` to `accepted`, assigns the driver and vehicle and sets `accepted_at`.
4. Unique partial constraints on the driver and vehicle, together with the conditional status update on the trip, prevent double assignment.
5. The system writes an audit event and returns the accepted trip.
6. If another driver won the race, or the trip is no longer `requested`, the caller receives a conflict response and no assignment is made.
7. A repeated acceptance with the same idempotency key returns the original accepted result; it does not reassign.

**Postcondition:** The trip has exactly one assigned driver and one assigned vehicle, is `accepted`, and no other active trip references that driver or vehicle.

**Failure handling:** Ineligible driver/vehicle returns a defined authorization or validation error; a lost race returns a conflict; an already-assigned trip cannot be reassigned; a repeated request is idempotent.

**Functional requirements:**

- **R2.1** Only an authenticated customer with an `approved` driver profile may accept a trip; an admin account may not act as a driver in the MVP.
- **R2.2** The selected vehicle must belong to the driver, be `approved`, and have no other active trip.
- **R2.3** The driver must have no other active trip, and the passenger and driver must be different users.
- **R2.4** Acceptance must be atomic: exactly one driver and one vehicle may be assigned to a trip, and a trip may be assigned only once in the MVP.
- **R2.5** The trip must be in `requested` status at the moment of acceptance; terminal, expired or already-accepted trips must be rejected.
- **R2.6** Acceptance must write the assignment and status change together and must be audited.
- **R2.7** Acceptance must be idempotent and must return a conflict to losing concurrent callers. An identical retry with the same key returns the original accepted result even though the trip is no longer `requested`; the idempotency lookup precedes the status check.

**Verification intent:** Two concurrent acceptances produce one success and one conflict; ineligible driver/vehicle tests; database rejection of duplicate active assignments; idempotency replay; audit query.

### 3.3 R3 - Passenger or driver retrieves current trip details and progress

**Actor:** The passenger who owns the trip, the assigned driver, or a read-only admin.

**Preconditions:** The caller is authenticated and authorised for the trip. UUID knowledge alone is not authorization.

**Workflow:**

1. The caller requests a trip by identifier, or requests the current active trip through a filtered list.
2. The system loads the trip and authorises the caller against the trip's passenger, assigned driver or admin privilege.
3. The system returns the current status, route summary, agreed fare and currency, payment method and current payment status, assigned driver/vehicle summary, lifecycle timestamps, latest location sample and review state.
4. The assigned driver may append location samples for an active assigned trip; this is a supporting write operation, not a sixth core action.
5. List responses are paginated, filterable by status and sortable by a bounded set of fields.
6. Read endpoints never mutate trip, payment or review state.

**Postcondition:** The caller sees an authorised, current view. Unauthorised callers see no trip data.

**Failure handling:** Unauthenticated callers receive an authentication error; authenticated non-participants receive a not-found or forbidden response as defined in Stage 4 without leaking trip existence or personal data; stale or invalid pagination cursors are rejected.

**Functional requirements:**

- **R3.1** Every read must enforce object-level authorization based on ownership or assignment; a UUID is never sufficient.
- **R3.2** The response must include the fields needed to understand current state without a second unbounded query: status, route, fare/currency, payment summary, driver/vehicle summary, timestamps, latest location and review state.
- **R3.3** "Latest progress" must come from the newest recorded location sample for that trip, not from another trip or an unverified client value.
- **R3.4** Only the assigned driver may append location samples, and only while the trip is active.
- **R3.5** Lists must define pagination, filtering and sorting and must not return unbounded results.
- **R3.6** Admin access is read-only and must not expose write capabilities.
- **R3.7** Responses must not leak personal data, payment secrets or other passengers' trip details.

**Verification intent:** Authorization matrix tests for owner, another passenger, assigned driver, another driver and admin; latest-location ordering test; pagination boundary tests; query plan for trip detail/history; no-mutation assertion for GET.

### 3.4 R4 - Driver completes the trip and the system records the payment outcome

**Actor:** The assigned driver, with the system performing the electronic payment attempt.

**Preconditions:** The trip is `in_progress`; the caller is the assigned driver; the trip has an agreed fare and currency; a payment method was selected at request time; the trip has no successful collection.

**Workflow:**

1. The driver submits completion with an idempotency key and, for cash, a confirmation that cash was collected.
2. The system verifies the caller is the assigned driver and that the trip is in `in_progress`.
3. In one transaction, the system sets the trip to `completed`, records `completed_at`, and confirms that the final amount equals the agreed fare and currency. The trip cannot be reopened in the MVP.
4. The system records a payment attempt:
   - **Cash:** the driver's confirmation becomes the `succeeded` outcome; no external provider is called.
   - **Electronic:** the system creates a `pending` attempt and records the provider result as `succeeded` or `failed`; an unknown/timeout result may remain `pending`. In this assessment the provider outcome is simulated or recorded directly; no real gateway is integrated.
5. The system writes audit events for completion and payment, and returns the completed trip with the payment outcome.
6. If an electronic collection fails, the trip remains completed with a failed/pending payment. The driver or system may retry the payment through the payment endpoint; the retry must not create a second successful collection.
7. A repeated completion request with the same idempotency key returns the original completion and payment outcome.

**Postcondition:** The trip is `completed`; its fare and currency are unchanged; at most one successful payment collection exists for the trip.

**Failure handling:** A non-assigned driver is rejected; completion from any status other than `in_progress` is rejected; a fare/currency mismatch is rejected; a duplicate successful collection is rejected; provider failures are recorded, not hidden.

**Functional requirements:**

- **R4.1** Only the assigned driver may complete the trip.
- **R4.2** Completion is allowed only from `in_progress`; `completed` is terminal and cannot be reopened.
- **R4.3** The final fare must equal the agreed fare and currency stored at request time; no current rate lookup or client-supplied amount may override it.
- **R4.4** The payment method must be the method recorded on the trip; payment amount and currency must equal the trip fare and currency.
- **R4.5** The system must record a payment outcome for cash and electronic methods, including failed and pending outcomes.
- **R4.6** At most one successful collection may exist per trip; retries must be idempotent and must not duplicate a successful collection. A replay with the same key returns the original outcome rather than re-running completion or collection.
- **R4.7** Trip completion must not be rolled back solely because an electronic collection fails; the failed/pending outcome remains visible and retryable.
- **R4.8** Completion and payment changes must be audited; settled financial records must not be deleted or silently rewritten. Controlled payment-attempt status transitions are permitted and audited.

**Verification intent:** Completion from each status; non-assigned driver; cash and electronic scenarios; failed-electronic retry; duplicate-success negative test; fare/currency mismatch negative test; payment query plan; audit query.

### 3.5 R5 - Passenger reviews their own completed trip

**Actor:** The passenger who owns the trip.

**Preconditions:** The trip is `completed`; the caller is the trip's passenger; no review exists for the trip; rating is an integer from 1 to 5; any comment is within the configured limit.

**Workflow:**

1. The passenger submits a rating and optional comment for a completed trip.
2. The system authorises the caller against the trip's passenger and verifies the trip is `completed`.
3. The system verifies that no review exists for the trip.
4. The system inserts the review with `trip_id`, `passenger_id`, rating, comment and `created_at`, and writes an audit event.
5. The system returns the created review. A duplicate attempt returns a conflict. Reviews are immutable in the MVP.

**Postcondition:** At most one review exists for the trip, written by its passenger.

**Failure handling:** A non-owner is rejected without exposing another passenger's trip; an incomplete trip is rejected; a duplicate review is rejected; an out-of-range rating or overlong comment is rejected.

**Functional requirements:**

- **R5.1** Only the passenger associated with the trip may create its review.
- **R5.2** The trip must be `completed` before a review is accepted.
- **R5.3** A trip may have at most one review in the MVP.
- **R5.4** Rating must be an integer from 1 to 5; the comment must be optional and bounded.
- **R5.5** Reviews are immutable; no edit or delete operation is exposed in the MVP.
- **R5.6** The passenger may read their review; the assigned driver and admin may read it read-only. No other user may write it.
- **R5.7** Review creation must be audited.

**Verification intent:** Owner/non-owner tests; incomplete-trip test; duplicate-review negative insert; rating boundary tests; immutable review assertion; audit query.

### 3.6 Supporting lifecycle operations

The following operations are required for a coherent trip lifecycle but are not additional core actions:

- The assigned driver marks arrival and starts the trip, enabling R4's `in_progress` precondition.
- The assigned driver appends location samples used by R3.
- A passenger or assigned driver may cancel a trip before it starts; unaccepted requests may expire. Exact actors, reasons, timing and forbidden transitions are defined in Stage 3.
- An admin approves, suspends or rejects driver profiles and vehicles, supporting BR6.
- The system expires stale requested trips and closes stale payment attempts.

These operations must obey the same authorization, audit and state-machine rules as the five core actions.

## 4. Non-functional requirements

| ID | Requirement | Acceptance / verification |
|---|---|---|
| **NFR1** | **Data integrity.** Every invariant in section 5.1 must be enforced in PostgreSQL with constraints, partial unique indexes or triggers, or by a documented transaction. Application validation is defence in depth, not the sole control. | Negative SQL tests reject each invariant; schema inspection shows the enforcement path. |
| **NFR2** | **Authorization.** Every endpoint authenticates the caller and enforces object-level authorization. UUID knowledge must never grant access. Admin privileges are least-privilege and read-only except eligibility management. | Authorization matrix tests for owner, unrelated customer, assigned driver, unrelated driver and admin; no data leakage in denied responses. |
| **NFR3** | **Financial correctness.** All money is stored as integer minor units with an ISO 4217 currency. No floating point is used. A trip has one agreed fare/currency; payment amount and currency must match it; at most one successful collection exists per trip. | Boundary/rounding tests; fare snapshot test; duplicate-success test; reconciliation query comparing trip and payment totals. |
| **NFR4** | **Auditability.** Append-only audit events cover trip creation, assignment, status changes, fare, payment outcomes, reviews and eligibility changes. Events record actor, action, entity, timestamp and relevant before/after data. Existing audit rows are not updated or deleted in normal operation. | Audit query for a complete trip; attempted update/delete rejected; audit coverage checklist. |
| **NFR5** | **Concurrency.** Acceptance, completion and payment attempts must be transactional. Unique partial indexes, row locks or conditional updates must prevent double assignment and double successful collection. Losing concurrent callers receive a defined conflict. | Two concurrent acceptances: one success, one conflict. Two concurrent successful payment attempts: one success, one rejection. Constraint inspection. |
| **NFR6** | **Performance.** The five actions must use bounded, index-supported access paths. On the seeded MVP dataset, target trip detail at p95 <= 300 ms, accept/complete at p95 <= 500 ms and first-page lists at p95 <= 500 ms. These are evidence targets, not production SLOs. | `EXPLAIN (ANALYZE, BUFFERS)` for the two heaviest queries shows index use and no unbounded scan; list pagination tests. |
| **NFR7** | **API consistency.** Endpoints are versioned under `/v1`, use JSON, UUID identifiers and ISO 8601 UTC timestamps, and return a standard error envelope. Lists define pagination, filtering and sorting. Unsafe retryable operations accept idempotency keys; an identical replay returns the stored response before current-state preconditions are re-evaluated, and a reused key with a different request fingerprint is rejected. | OpenAPI schema validation; contract tests for success and error envelopes; idempotency replay tests. |
| **NFR8** | **Security and privacy.** Collect only data needed for the workflow; restrict location and personal data to trip participants/admin; never commit secrets or log payment credentials. Retention and anonymisation are explicit Stage 3 decisions, not a claim of compliance with a specific law. | Authorization tests; secret scan; PII field review; documented retention decision in Stage 3. |
| **NFR9** | **Testability and evidence.** Migrations and seed data must be reproducible from a clean database. The proof must include five action queries, two query plans and three rejected invalid inserts, with raw logs and genuine screenshots. | Clean-database apply; query/plan capture; negative insert capture; evidence index review. |

## 5. Business rules, state vocabulary and exclusions

### 5.1 Business rules

| ID | Rule |
|---|---|
| **BR1** | Every trip belongs to exactly one passenger. |
| **BR2** | A trip has at most one assigned driver and at most one assigned vehicle. Driver and vehicle are assigned together or both remain unassigned. The passenger and assigned driver must be different users. |
| **BR3** | A passenger may have at most one active trip at a time. |
| **BR4** | A driver may have at most one active trip at a time. |
| **BR5** | A vehicle may be assigned to at most one active trip at a time. |
| **BR6** | Only a driver with an approved driver profile, using an approved vehicle they own that is not suspended, with no other active trip, may accept a requested trip. Eligibility is checked at acceptance; suspension does not silently reassign an active trip. |
| **BR7** | The agreed trip fare and currency are fixed when the trip is requested and preserved through completion. Later rate-card or driver-rate changes must not change an existing trip's fare. |
| **BR8** | Every monetary value uses integer minor units and an ISO 4217 currency code. No floating-point money and no implicit currency conversion are permitted. |
| **BR9** | A trip may have at most one successful payment collection. Retries, duplicate requests and provider callbacks must not create a second successful collection. |
| **BR10** | Only the passenger associated with a completed trip may create its review, and a trip may have at most one review in the MVP. |
| **BR11** | Reviews are immutable in the MVP: no edit or delete operation is exposed. |
| **BR12** | Trip status changes must follow an explicit state machine. Only the transitions defined in Stage 3 are allowed; active statuses are non-terminal and terminal statuses cannot be reopened. |
| **BR13** | UUIDs are opaque identifiers, not authorization. Every access must still check the caller's relationship to the resource. |
| **BR14** | Sensitive financial and audit history must not be casually deleted. The MVP exposes no delete endpoints and uses restrictive foreign keys; retention/deletion policy is decided in Stage 3. |
| **BR15** | Payment amount and currency must equal the trip's agreed fare and currency; a payment must not carry a different amount or currency from the trip. |
| **BR16** | The driver/vehicle assignment is immutable after acceptance in the MVP. A trip cannot be silently reassigned; an operational exception must be an explicit, audited cancellation/admin action in Stage 3. |
| **BR17** | Trip completion and payment outcome are separate facts. A failed or pending electronic collection does not reopen or un-complete the trip, and a completed trip does not imply successful payment. |

### 5.2 Status vocabulary

| Domain | Statuses | Notes |
|---|---|---|
| Trip | `requested`, `accepted`, `driver_arriving`, `in_progress`, `completed`, `cancelled`, `expired` | `requested`, `accepted`, `driver_arriving` and `in_progress` are **active**. `completed`, `cancelled` and `expired` are **terminal**. |
| Payment | `pending`, `succeeded`, `failed` | Payment status is independent of trip status. At most one `succeeded` payment may exist per trip. |
| Driver profile | `pending`, `approved`, `suspended`, `rejected` | Only `approved` permits acceptance. |
| Vehicle | `pending`, `approved`, `suspended` | Only an approved, active vehicle may be assigned. |
| Account | `active`, `disabled` | A disabled account cannot authenticate or act. |
| Review | No lifecycle status | Reviews are immutable after creation. |

The implied happy path is `requested -> accepted -> driver_arriving -> in_progress -> completed`. The Stage 3 state machine must define all allowed and forbidden transitions, including cancellation and expiry. R4 is permitted only from `in_progress`; terminal trip states are final.

### 5.3 MVP exclusions

The following are explicitly out of scope and must not appear as implemented features:

- A user-facing application, frontend, production API server or ORM.
- Real payment-gateway integration, card-data storage, PCI scope, refunds, chargebacks or driver payouts/settlements.
- Driver onboarding, KYC, background checks, document expiry and compliance workflows.
- Pricing engines, surge pricing, tolls, waiting fees, promotions, scheduled trips, multi-stop trips or pooled rides.
- Dispatch optimisation, driver online presence, proximity ranking or geo-matching; in the MVP any eligible driver may accept a requested trip on a first-valid-accept basis.
- In-app chat, push notifications, phone-number masking or customer-support tooling.
- Review moderation, review editing/deletion, or passenger ratings of drivers beyond the single passenger review in R5.
- Multi-currency conversion; each trip has one currency and no FX is performed.
- Production WebSocket/SSE infrastructure; Stage 4 analyses the transport choice, while Stage 5 proves the database only.
- A final retention/deletion implementation; Stage 3 must make and document that decision.

### 5.4 Conflicts and resolutions

**C1 - Account role versus driver capability.** Treating `driver` as a `users.role` would contradict the requirement that a user has a `customer` or `admin` account role and would prevent a driver from also being a passenger. **Resolution:** `users.role` is limited to `customer`/`admin`; driver eligibility is a separate `driver_profiles.status`. This is the only role model used in later stages.

**C2 - One active trip per passenger versus per driver.** BR3 and BR4 apply per capacity. A user with both an approved driver profile and a passenger account could theoretically have one active trip as passenger and one as driver. **Resolution:** the MVP enforces the two per-capacity rules and forbids the same user from being passenger and driver on the same trip. A stricter "one active trip per human across all capacities" rule is an explicit open decision (A12), not silently assumed.

**C3 - Fare preservation versus later fare adjustments.** R4 could be read as allowing a final fare different from the requested quote. **Resolution:** the MVP fare is fixed at request time; final amount equals agreed amount. Surge, tolls, waiting charges and post-trip adjustments are excluded. A future adjustment feature would require an explicit adjustment entity and fare versioning, not mutation of the original fare.

**C4 - Trip completion versus payment failure.** R4 requires a payment outcome, but an electronic collection can fail. **Resolution:** completion is committed independently; the payment attempt records `failed` or `pending`; retries are allowed; the trip is never reopened; at most one attempt may succeed. This preserves both operational truth and financial correctness.

**C5 - Review immutability versus moderation.** The MVP has no moderation requirement. **Resolution:** reviews are immutable and admin read-only; moderation/editing is out of scope. If moderation is added later, it must be a separate audited action, not an in-place edit that destroys history.

**C6 - Audit retention versus deletion/privacy.** BR14 requires preservation, while privacy may require deletion. No specific law or retention period is claimed. **Resolution:** no destructive endpoints in the MVP; Stage 3 must define soft versus hard deletion, PII minimisation/anonymisation and retention periods for location, financial and audit data, with legal review treated as an external dependency.

## 6. Assumptions requiring later decisions

These are explicit assumptions, not approved regulatory or product claims. Stage 2-4 must convert them into design decisions or raise them for approval.

| ID | Assumption / open decision | Proposed default for planning | Decision stage |
|---|---|---|---|
| **A1** | Fare calculation and rounding policy. | The fare is server-calculated from a simple MVP rate policy, rounded once to minor units. No surge, tolls, waiting fees or post-trip adjustment. Exact formula to be specified. | Stage 2 |
| **A2** | Supported currencies and FX. | One ISO 4217 currency per trip; no conversion. The deployment's supported list is configuration, not an exchange-rate service. | Stage 2 |
| **A3** | Driver vehicle cardinality. | A driver may register multiple vehicles; acceptance selects one approved vehicle owned by the driver. No vehicle swap after acceptance. | Stage 2 |
| **A4** | Review limits and moderation. | Passenger-to-driver review only; integer 1-5; optional comment up to 2,000 characters; immutable; no moderation/editing/deletion. | Stage 2 / Stage 4 |
| **A5** | Payment failure and cash confirmation. | Electronic failure leaves the trip completed with `failed`/`pending` payment; retries allowed. Cash is confirmed by the assigned driver only; no passenger confirmation. No refunds/chargebacks. | Stage 2 / Stage 3 |
| **A6** | Cancellation and expiry policy. | Cancellation/expiry are supporting transitions, not core actions. Actors, reasons, TTL and whether a fee applies are defined in Stage 3; no refunds in the MVP. | Stage 3 |
| **A7** | Retention and deletion. | No specific law is claimed. Stage 3 decides soft versus hard deletion, PII anonymisation and retention periods for location, financial and audit records. | Stage 3 |
| **A8** | Admin scope. | Admin may approve/suspend/reject drivers and vehicles and read operational/audit data. No impersonation or financial mutation. | Stage 2 / Stage 4 |
| **A9** | Idempotency key scope and lifetime. | Keys are scoped to principal + operation, stored with a request fingerprint, and expire after a configurable period. Exact TTL is an API design decision. | Stage 4 |
| **A10** | Location sampling and retention. | Store an append-only location sample per update with timestamp and accuracy; expose the latest sample in trip detail. Sampling frequency, precision and location retention are to be confirmed. | Stage 2 / Stage 3 |
| **A11** | Authentication mechanism. | API contracts assume an external bearer-token/OIDC-style identity; login, password storage and token issuance are outside the database proof. | Stage 4 |
| **A12** | Cross-capacity active trips. | Per-capacity active-trip rules are enforced. Whether a dual-capability user may hold one active trip as passenger and another as driver is unresolved; the stricter per-user rule would require additional cross-table enforcement. | Stage 2 / Stage 3 |
| **A13** | Driver presence and matching. | No online/offline presence, proximity ranking or dispatch optimisation. Any eligible driver may accept a requested trip; first valid acceptance wins. | Stage 2 |
| **A14** | Time representation. | Persist UTC timestamps; display-time localisation is outside the MVP. Exact `created_at`/`updated_at`/`deleted_at` policy is decided in Stage 3. | Stage 2 / Stage 3 |

## 7. Requirements traceability matrix

Entity names are provisional pending Stage 2; endpoint names are planned pending Stage 4. The mapping intent is binding even if names are refined. "Verification" identifies the later evidence that will demonstrate the requirement.

### 7.1 Core actions

| Requirement | Primary entities | Database constraints / triggers | Indexes | Planned API endpoints | Verification |
|---|---|---|---|---|---|
| **R1** (R1.1-R1.7) Passenger requests trip | `users`, `trips`, `idempotency_keys`, `audit_events` | `trips.passenger_id` FK NOT NULL; trip status enum; fare > 0; ISO 4217 currency check; partial unique active trip per passenger; unique `(principal, operation, key)`; audit insert | `trips(passenger_id, created_at DESC)`; partial unique active-passenger index | `POST /v1/trips` | Duplicate active request rejected; idempotent replay returns same trip; fare snapshot test; negative insert for second active trip. |
| **R2** (R2.1-R2.7) Eligible driver accepts trip | `trips`, `driver_profiles`, `vehicles`, `users`, `idempotency_keys`, `audit_events` | Approved driver profile; approved owned vehicle; both-or-neither assignment check; partial unique active trip per driver and per vehicle; passenger <> driver; conditional status update; unique `(principal, operation, key)`; audit insert | Partial unique active-driver and active-vehicle indexes; `trips(status, created_at)` for requested queue; `vehicles(driver_id, status)` | `GET /v1/trips?status=requested`; `POST /v1/trips/{tripId}/accept` | Concurrent accept: one success and one conflict; ineligible driver/vehicle rejected; duplicate active assignment rejected; replay test. |
| **R3** (R3.1-R3.7) Retrieve current details/progress | `trips`, `trip_location_samples`, `users`, `driver_profiles`, `vehicles`, `payments`, `reviews` | FKs to trip and users; latitude/longitude range checks; `recorded_at` NOT NULL; object-level authorization policy; no write path through GET | `trip_location_samples(trip_id, recorded_at DESC)`; `trips(passenger_id, created_at DESC)`; `trips(driver_id, created_at DESC)` | `GET /v1/trips/{tripId}`; `GET /v1/trips?status=active`; `POST /v1/trips/{tripId}/location` (supporting) | Authorization matrix for owner/other passenger/assigned driver/other driver/admin; latest-sample ordering; pagination tests; `EXPLAIN` for detail/history. |
| **R4** (R4.1-R4.8) Complete trip and record payment outcome | `trips`, `payments`, `users`, `driver_profiles`, `audit_events` | Completion only from `in_progress`; assigned driver check; fare/currency equality with trip; payment method/status enums; one successful payment per trip; controlled attempt transitions with no deletion; idempotency; audit insert | `payments(trip_id, created_at DESC)`; partial unique successful payment per trip; `trips(driver_id, status)` | `POST /v1/trips/{tripId}/complete`; `POST /v1/trips/{tripId}/payments`; `GET /v1/trips/{tripId}/payments` | Cash and electronic flows; failed electronic retry; duplicate success rejected; fare/currency mismatch rejected; payment query plan. |
| **R5** (R5.1-R5.7) Passenger reviews completed trip | `trips`, `reviews`, `users`, `driver_profiles`, `audit_events` | Unique review per trip; composite FK `(trip_id, passenger_id)` to trip ownership; rating 1-5; comment length; completed-trip trigger; immutable review trigger; audit insert | Unique `reviews(trip_id)`; `reviews(driver_id, created_at DESC)` if driver snapshot is stored; `reviews(passenger_id, created_at DESC)` | `POST /v1/trips/{tripId}/reviews`; `GET /v1/trips/{tripId}/review`; `GET /v1/drivers/{driverId}/reviews` | Non-owner rejected; incomplete trip rejected; duplicate review rejected; rating boundary tests; immutability test. |

### 7.2 Non-functional requirements

| Requirement | Entities / data | Constraints / indexes | Planned API / evidence | Verification |
|---|---|---|---|---|
| **NFR1** Data integrity | All entities | PKs, FKs, CHECK constraints, partial unique indexes, transition/immutability triggers | All write endpoints; schema inspection | Negative SQL tests for each invariant; constraint catalog evidence. |
| **NFR2** Authorization | `users`, `driver_profiles`, `trips` | Ownership FKs; no UUID-based authorization; role/eligibility checks; admin read policy | All endpoints; auth matrix | 401/403/404 tests for owner, unrelated customer, assigned/unrelated driver and admin. |
| **NFR3** Financial correctness | `trips`, `payments` | Integer minor units; ISO 4217 checks; fare immutability; amount/currency equality; one success per trip | `POST /v1/trips`; completion/payment endpoints | Boundary/rounding tests; duplicate-success rejection; reconciliation query. |
| **NFR4** Auditability | `audit_events` | Append-only trigger; actor/action/entity/timestamp fields; restrictive FKs | `GET /v1/admin/audit-events` | Complete trip audit trail; update/delete rejection; coverage checklist. |
| **NFR5** Concurrency | `trips`, `payments` | Partial unique indexes; row locks/conditional updates; one-success constraint | Accept, complete and payment endpoints | Concurrent accept and concurrent payment tests; one winner only. |
| **NFR6** Performance | `trips`, `payments`, `trip_location_samples` | Access-path indexes listed in 7.1; bounded list queries | All five actions | Two `EXPLAIN (ANALYZE, BUFFERS)` plans; p95 targets on seeded data; no unbounded scan. |
| **NFR7** API consistency | `idempotency_keys` | Unique `(principal, operation, key)`; expiry field; request fingerprint | All `/v1` endpoints; OpenAPI | Schema validation; error-envelope tests; idempotency replay and expiry tests. |
| **NFR8** Security/privacy | `users`, `trips`, `trip_location_samples` | Field minimisation; location access scope; no secret columns in repo | All endpoints; retention decision | Authorization tests; secret scan; PII/location field review; Stage 3 retention note. |
| **NFR9** Testability/evidence | Migrations, seed, query scripts | Reproducible apply; deterministic seed | Five action queries; evidence folder | Clean-database apply; two plans; three rejected inserts; screenshot review. |

### 7.3 Business rules

| Rule | Entities | Constraints / indexes | Planned API | Verification |
|---|---|---|---|---|
| **BR1** Exactly one passenger per trip | `trips`, `users` | `trips.passenger_id` NOT NULL FK | R1 | NOT NULL/FK negative test. |
| **BR2** At most one driver/vehicle; both-or-neither; distinct passenger/driver | `trips`, `driver_profiles`, `vehicles` | Single nullable driver/vehicle FKs; check that both are set or both null; distinct-user check | R2 | Assignment pair tests; self-assignment rejection. |
| **BR3** One active trip per passenger | `trips` | Partial unique active-passenger index | R1 | Second active trip rejected. |
| **BR4** One active trip per driver | `trips` | Partial unique active-driver index | R2 | Second active acceptance rejected. |
| **BR5** One active trip per vehicle | `trips` | Partial unique active-vehicle index | R2 | Vehicle reuse conflict. |
| **BR6** Approved, eligible driver only | `driver_profiles`, `vehicles`, `trips` | Profile/vehicle status checks; ownership check; transactional acceptance; `driver_profiles(status)` and `vehicles(driver_id, status)` indexes | `POST /v1/trips/{tripId}/accept`; `PATCH /v1/admin/drivers/{driverId}/eligibility`; `PATCH /v1/admin/vehicles/{vehicleId}/eligibility` | Unapproved/suspended driver and wrong-owner vehicle tests. |
| **BR7** Fare/currency preserved | `trips`, `payments` | Fare/currency NOT NULL; immutability trigger; payment equality check | R1, R4 | Update fare after request rejected; payment mismatch rejected. |
| **BR8** Integer minor units and ISO 4217 | `trips`, `payments` | BIGINT minor-unit checks; currency regex/length; no floating-point columns | R1, R4 | Invalid amount/currency negative tests. |
| **BR9** One successful collection per trip | `payments`, `idempotency_keys` | Partial unique successful-payment index; unique `(principal, operation, key)`; retry transaction | R4 payment endpoint | Second successful payment rejected; retry returns original outcome. |
| **BR10** Only passenger of completed trip reviews; one review | `trips`, `reviews` | Composite ownership FK; unique `reviews(trip_id)`; completed-trip trigger | R5 | Non-owner, incomplete and duplicate review tests. |
| **BR11** Reviews immutable | `reviews` | Update/delete-rejecting trigger or permissions | R5 read endpoints | Update/delete attempts rejected. |
| **BR12** Explicit state machine | `trips` | Status enum/check; transition trigger; partial indexes use active statuses | All trip endpoints | Forbidden transition tests; state-machine evidence. |
| **BR13** UUID is not authorization | All resources | No DB substitute; API ownership/assignment checks | All endpoints | Cross-tenant UUID access tests. |
| **BR14** Financial/audit history not casually deleted | `payments`, `audit_events`, `reviews`, `trips` | No delete endpoints; `ON DELETE RESTRICT`; append-only triggers; retention policy later | `GET /v1/admin/audit-events`; read-only operational endpoints | Delete/update rejection; retention decision recorded. |
| **BR15** Payment matches trip amount/currency | `payments`, `trips` | Trigger/check comparing payment to trip; same-currency rule | R4 | Amount/currency mismatch rejected. |
| **BR16** Assignment immutable after accept | `trips` | Driver/vehicle change trigger; active partial indexes | R2 | Reassignment attempt rejected. |
| **BR17** Completion and payment are independent | `trips`, `payments` | Trip status and payment status separate columns/enums; no cascade from payment failure | R4 | Failed electronic payment leaves trip completed and retryable. |

## 8. Verification plan

Verification will be evidence-based, not assertion-based. Each core action will have one representative query, and the database proof will capture the results, plans and constraint failures.

| Requirement group | Verification method | Required evidence |
|---|---|---|
| **R1** Request trip | API contract tests; DB check for second active trip; idempotency replay; fare snapshot assertion | Q1: passenger active-trip/eligibility lookup. Negative insert: second active trip for same passenger. |
| **R2** Accept trip | Concurrent acceptance test; eligibility fixtures; duplicate active driver/vehicle checks; replay | Q2: available requested trips with eligible driver/vehicle. One success + one conflict in concurrent test. |
| **R3** Retrieve progress | Authorization matrix; latest-location ordering; pagination/filter/sort; plan inspection | Q3: trip detail with latest location and participant data. `EXPLAIN (ANALYZE, BUFFERS)` for the access path. |
| **R4** Complete and pay | Cash and electronic scenarios; failed electronic retry; duplicate-success rejection; fare/currency mismatch; completion state checks | Q4: completed trip with payment outcome/reconciliation. Negative insert: second successful payment for the same trip. |
| **R5** Review | Owner/non-owner, completed/incomplete, duplicate and rating-boundary tests; immutability assertion | Q5: review by trip/passenger. Negative insert: second review for the same trip. |
| **NFR1-NFR5** Integrity, auth, money, audit, concurrency | Constraint catalog; negative SQL tests; auth matrix; concurrent sessions; audit trail query | Constraint/index inspection; rejected inserts; audit output; concurrency transcript. |
| **NFR6** Performance | Seeded dataset; `EXPLAIN (ANALYZE, BUFFERS)` on the two heaviest queries; p95 targets | Query plans and timings. Expected heaviest: R2 available-trip search and R3 trip detail/latest-location; confirm in Stage 5. |
| **NFR7-NFR9** API consistency, privacy, evidence | OpenAPI validation; error-envelope tests; secret/PII review; clean-database apply; evidence index | OpenAPI file; contract test results; retention note; reproducible migration/seed log; screenshots. |
| **BR1-BR17** Business rules | SQL constraint/trigger tests and targeted negative operations | At minimum three rejected inserts: (1) second active trip for a passenger, (2) second successful payment for a trip, (3) second review for a trip. Additional negatives cover unapproved drivers, wrong-owner vehicles and forbidden transitions. |

The required screenshots must show genuine `psql` query plans and rejection messages, accompanied by raw text logs for auditability. The exact capture format remains an evidence-tooling decision; no GUI client was verified in Stage 0.

## 9. Approval and open decisions

This document fixes the requirements baseline but does not silently resolve the open assumptions in section 6. The material unresolved items are:

- **A1-A5**: fare policy, currency support, vehicle cardinality, review limits, payment failure/cash semantics.
- **A6-A7**: cancellation/expiry policy and retention/deletion policy.
- **A8-A14**: admin scope, idempotency TTL, location sampling, authentication, cross-capacity active trips, driver presence/matching and timestamp policy.
- **C2**: whether a dual-capability user may hold one active trip as passenger and another as driver. The MVP currently enforces per-capacity rules and forbids the same user on both sides of one trip.
- **C6**: how audit preservation coexists with privacy deletion; no specific law is claimed.

Stage 2 will define the canonical entity catalog, fields, identifiers, cardinalities and ER diagram. It must not introduce new product scope or contradict this baseline. Stage 2 should start only after this requirements document and the proposed defaults are approved.

**Stage 1 implementation status:** documentation only. No SQL, migration, database table, application code, frontend or API server was created or modified.
