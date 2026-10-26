# RideFlow - API Design and Architecture Specification

| Field | Value |
|---|---|
| Assessment | Task 3 - API Design and Data Modeling |
| Stage | 4 - API Specification and OpenAPI Contract Design |
| Status | Approved |
| Baselines | `docs/requirements.md` (Stage 1), `docs/data-model.md` (Stage 2), `docs/er-diagram.md` (Stage 2), `docs/design-decisions.md` (Stage 3), `docs/state-machines.md` (Stage 3) |
| Companion Contract | `docs/openapi.yaml` (OpenAPI 3.1.0) |
| Scope | API architecture, endpoint semantics, authorization, error envelopes, idempotency, REST vs. GraphQL, and real-time design. No backend implementation or server deployment. |

---

## 1. Executive Summary & Design Philosophy

RideFlow is a ride-hailing platform providing point-to-point transportation. This API specification establishes the complete external contract for the RideFlow MVP. Every endpoint, parameter, response schema, and error behavior directly traces back to the approved Stage 1 requirements baseline (`docs/requirements.md`), Stage 2 entity model (`docs/data-model.md`), and Stage 3 state machine and index decisions (`docs/design-decisions.md`, `docs/state-machines.md`).

### Architectural Principles
1. **Contract-Driven & PostgreSQL-Aligned**: The API contract declarative types, nullability, integer minor-unit currencies, UUID identifiers, and state transition boundaries strictly reflect the relational and trigger invariants of the underlying PostgreSQL schema.
2. **Defense in Depth**: Application-level and API gateway checks perform initial validation and object-level authorization, while the PostgreSQL database enforces terminal business invariants (e.g. partial unique active trip limits, immutable fare tuples, state transition triggers).
3. **Explicit Object-Level Authorization (BOLA Prevention)**: UUIDs are opaque resource locators, never capabilities or access tokens. Every endpoint strictly authenticates the caller via Bearer tokens (OAuth2/OIDC JWT) and verifies ownership, active assignment, or explicit admin roles prior to inspecting or mutating resources.
4. **Predictable Standard Envelopes**: All responses adhere to unified JSON envelopes for single-resource returns, paginated list returns, and a custom NFR7 error envelope inspired by RFC 7807 Problem Details.
5. **Robust Idempotency**: All unsafe mutating endpoints (`POST`, `PATCH`) accept client-supplied `Idempotency-Key` headers, unless explicitly excluded by their endpoint contract (such as high-frequency telemetry samples). Cached execution fingerprints ensure replay safety across unreliable networks.

---

## 2. Global API Conventions

### 2.1 Protocol, Versioning, and Content Types
- **Base URL**: `https://api.rideflow.example.com/v1`
- **Versioning Strategy**: Major version in URI path (`/v1`). Minor, backward-compatible additions (e.g., adding an optional field) do not increment the URI.
- **Content Negotiation**:
  - Request: `Content-Type: application/json`
  - Response: `Content-Type: application/json; charset=utf-8`

### 2.2 Identifiers and Data Types
- **UUIDs**: All entity identifiers (`id`, `passenger_id`, `driver_id`, `vehicle_id`, `trip_id`, etc.) are canonical 36-character lowercase RFC 4122 UUID v4 strings (e.g., `018d3f62-7b1a-7b3e-8c42-5f69a1e09101`).
- **Timestamps**: All timestamps are formatted according to ISO 8601 / RFC 3339 in UTC with explicit timezone offset `Z` (e.g., `2026-10-26T12:00:00.000Z`).
- **Money & Currencies (NFR3, A1, A2)**: Floating-point numbers are strictly forbidden for monetary amounts. Fares and payments are represented as non-negative 64-bit integer minor currency units (`bigint` mapped to JSON integer, e.g., `550000` = 5,500.00 NGN) accompanied by an explicit 3-letter ISO 4217 alphabetic uppercase currency code (`"NGN"`).
- **Coordinates**: Latitudes (`[-90.000000, 90.000000]`) and longitudes (`[-180.000000, 180.000000]`) are formatted as JSON numbers with up to 6 decimal places of precision (~0.1m ground precision).

### 2.3 Authentication and Authorization (NFR2, D9)
- **Mechanism**: HTTP Bearer Authentication (`Authorization: Bearer <jwt>`) via OpenID Connect / OAuth2.
- **Token Claims**: The validated JWT provides:
  - `sub`: Caller's unique `user_id` (UUID).
  - `role`: Platform account role, strictly `'customer'` or `'admin'`.
  - `scope`: Granted OAuth2 scopes (e.g., `rideflow:customer`, `rideflow:admin`).
- **Capability Derivation**:
  - `Customer`: May act as a passenger on trips they request.
  - `Driver`: A customer user who possesses an associated `driver_profiles` record in `status = 'approved'` and is assigned an `approved` vehicle. Driver capability is orthogonal to the platform role (`role = 'customer'`).
  - `Admin`: Oversight role with read-only access across platform resources and restricted write capabilities solely for driver/vehicle eligibility management (`/v1/admin/*`). Admins cannot request trips, act as drivers, or author reviews.
- **Object-Level Authorization Rules**:
  - A passenger may only view or review trips where `trips.passenger_id == jwt.sub`.
  - A driver may only view full trip details, stream telemetry, or trigger completion for trips where `trips.driver_id == jwt.sub`.
  - Non-participant customers attempting to access another user's trip receive `404 Not Found` (to prevent ID harvesting and existence leakage) or `403 Forbidden` if authorization context is already exposed.

### 2.4 Standard Response Envelopes
To satisfy NFR7 and ensure uniform client consumption, RideFlow uses standardized top-level JSON envelopes:

#### 2.4.1 Single Resource Success Envelope
```json
{
  "data": { ... }
}
```

#### 2.4.2 Paginated List Success Envelope
List endpoints use cursor-based (or offset-based bounded) pagination:
```json
{
  "data": [ ... ],
  "pagination": {
    "limit": 20,
    "has_more": false,
    "next_cursor": "eyJjcmVhdGVkX2F0IjoiMjAyNi0xMC0yNlQxMjowMDowMFoiLCJpZCI6IjAxOGQzZi4uLiJ9",
    "total_count": 1
  }
}
```
- **Pagination Defaults**: Default `limit = 20`, maximum `limit = 100`.
- **Sorting**: Specified via `sort_by` and `order` (`asc` | `desc`). Only explicitly indexed columns are permitted; arbitrary sort keys return `400 Bad Request`.

#### 2.4.3 Standard Error Envelope
All error responses (4xx, 5xx) use a custom NFR7 error envelope inspired by RFC 7807 Problem Details semantics:
```json
{
  "error": {
    "code": "ACTIVE_TRIP_CONFLICT",
    "message": "Passenger already has an active trip in progress.",
    "status": 409,
    "details": [
      {
        "field": "passenger_id",
        "reason": "Passenger has existing trip with status 'in_progress'"
      }
    ],
    "timestamp": "2026-10-26T12:00:00.000Z",
    "request_id": "req_018d3f627b1a"
  }
}
```

### 2.5 Standard Error Codes Vocabulary
| HTTP Status | Error Code | Description / Trigger Condition |
|---|---|---|
| `400` | `VALIDATION_ERROR` | Malformed JSON, coordinate out of bounds, rating not 1–5, invalid currency format. |
| `400` | `INVALID_CURSOR` | Pagination cursor is expired, malformed, or tampered with. |
| `401` | `UNAUTHENTICATED` | Missing, expired, or cryptographically invalid Bearer JWT. |
| `403` | `FORBIDDEN` | Caller lacks permission (e.g. non-admin calling admin endpoint, admin attempting to request a trip). |
| `404` | `RESOURCE_NOT_FOUND` | Target resource does not exist, or caller is not authorized to know of its existence (ID masking). |
| `409` | `ACTIVE_TRIP_CONFLICT` | Passenger (BR3) or Driver (BR4) or Vehicle (BR5) already engaged in an active trip. |
| `409` | `TRIP_ALREADY_ACCEPTED` | Another driver won the race to accept the requested trip (R2 concurrent acceptance). |
| `409` | `INVALID_STATE_TRANSITION` | Attempted lifecycle mutation violates the state machine allowlist (e.g., `completed -> cancelled`). |
| `409` | `DUPLICATE_REVIEW` | Trip already has an existing passenger review (BR10). |
| `409` | `PAYMENT_ALREADY_SUCCEEDED` | Attempting to record successful collection on a trip that already has a settled payment (BR9). |
| `409` | `IDEMPOTENCY_CONFLICT` | `Idempotency-Key` was previously submitted with a different request payload fingerprint. |
| `422` | `INELIGIBLE_DRIVER` | Driver profile status is not `approved`, or vehicle is suspended / not owned by driver (BR6). |
| `422` | `TRIP_NOT_COMPLETED` | Attempting to review a trip whose status is not yet `completed` (BR10, R5.2). |
| `500` | `INTERNAL_SERVER_ERROR` | Unhandled system exception or unexpected database failure. |

### 2.6 Idempotency Specification (NFR7, A9)
- **Header**: `Idempotency-Key: <string>` (Required on mutating `POST` and state-transition `PATCH` requests, unless explicitly excluded by the endpoint contract; length 8–255 characters).
- **Explicit Telemetry Exception**: High-frequency location telemetry updates (`POST /v1/trips/{id}/locations`) are explicitly excluded from the `Idempotency-Key` requirement. In accordance with the approved data model (`docs/data-model.md`), the compound index `trip_location_samples(trip_id, recorded_at DESC, id DESC)` supports telemetry retrieval and deterministic ordering (with `id DESC` resolving timestamp collisions when selecting the latest sample). The schema and API do not enforce sample-level deduplication; repeated submissions of the same sample (e.g. on client retry) may create duplicate rows, which is acceptable for loss-tolerant, append-only operational telemetry and avoids write amplification on `idempotency_keys` during periodic GPS pings (every 3–5 seconds).
- **Fingerprinting**: The server computes a SHA-256 fingerprint over: `(principal_user_id, operation, normalized_request_body)`.
- **Execution Semantics**:
  1. **Precedence**: The server performs an idempotency lookup *before* testing state preconditions.
  2. **Identical Replay**: If the `Idempotency-Key` exists and the `request_hash` matches:
     - The server returns the cached HTTP status code and response body without re-executing any business logic or database writes.
  3. **Mismatched Replay**: If the `Idempotency-Key` exists but the `request_hash` differs:
     - The server rejects the call immediately with `409 Conflict` (`IDEMPOTENCY_CONFLICT`).
  4. **First Call**: If key is not found, the operation executes within a database transaction. Upon successful completion, the HTTP response status, response body, and hash are committed to `idempotency_keys`.
- **Retention & TTL**: Stored idempotency records expire after 24 hours (configurable TTL) via background pruning.

---

## 3. Core Action Endpoint Specifications (R1–R5)

### 3.1 R1 — Passenger Requests a Trip

- **Method & Path**: `POST /v1/trips`
- **Purpose**: Creates a new point-to-point trip request with an agreed server-calculated fare snapshot.
- **Allowed Actor**: Authenticated Customer acting in passenger capacity (`role = 'customer'`).
- **Authorization**: `jwt.sub` must be an active customer account. Admins are rejected with `403 Forbidden`. Caller cannot specify a `passenger_id` other than their own `jwt.sub`.
- **Headers**:
  - `Authorization: Bearer <token>` (Required)
  - `Idempotency-Key: <uuid/string>` (Required)
- **Request Body**:
  ```json
  {
    "pickup_latitude": 6.524379,
    "pickup_longitude": 3.379206,
    "dropoff_latitude": 6.601838,
    "dropoff_longitude": 3.351486,
    "pickup_address": "Commercial Avenue, Yaba, Lagos",
    "dropoff_address": "Ikeja City Mall, Alausa, Ikeja",
    "payment_method": "cash"
  }
  ```
- **Validation Rules**:
  - `pickup_latitude` / `dropoff_latitude`: Number between `-90.0` and `90.0`.
  - `pickup_longitude` / `dropoff_longitude`: Number between `-180.0` and `180.0`.
  - `pickup_address` / `dropoff_address`: Optional string, max 500 characters.
  - `payment_method`: String, strictly `'cash'` or `'electronic'`.
- **Business Logic & State Invariants**:
  - Verifies passenger has no existing active trip (`trips.passenger_id` not in `requested`, `accepted`, `driver_arriving`, `in_progress`). Violations return `409 Conflict` (`ACTIVE_TRIP_CONFLICT`).
  - Computes server-side fare in integer minor units (NGN kobo) using deterministic pricing rules: `base_fare + (distance * rate) + (duration * rate)` with integer rounding (`fare_minor > 0`). Client amounts are not accepted.
  - Sets `currency = 'NGN'`.
  - Sets `status = 'requested'`, `requested_at = now()`.
  - Leaves `driver_id = null`, `vehicle_id = null`, `accepted_at = null`.
- **Success Response**: `201 Created`
  ```json
  {
    "data": {
      "id": "018d3f62-7b1a-7b3e-8c42-5f69a1e09101",
      "passenger_id": "018d3f62-1111-7b3e-8c42-5f69a1e09111",
      "driver_id": null,
      "vehicle_id": null,
      "status": "requested",
      "pickup_latitude": 6.524379,
      "pickup_longitude": 3.379206,
      "dropoff_latitude": 6.601838,
      "dropoff_longitude": 3.351486,
      "pickup_address": "Commercial Avenue, Yaba, Lagos",
      "dropoff_address": "Ikeja City Mall, Alausa, Ikeja",
      "fare_minor": 450000,
      "currency": "NGN",
      "payment_method": "cash",
      "requested_at": "2026-10-26T12:00:00.000Z",
      "accepted_at": null,
      "driver_arriving_at": null,
      "started_at": null,
      "completed_at": null,
      "cancelled_at": null,
      "cancellation_reason": null,
      "expired_at": null,
      "created_at": "2026-10-26T12:00:00.000Z",
      "updated_at": "2026-10-26T12:00:00.000Z"
    }
  }
  ```

---

### 3.2 R2 — Eligible Driver Accepts a Trip

- **Method & Path**: `POST /v1/trips/{id}/accept`
- **Purpose**: Atomically assigns an eligible driver and approved vehicle to a `requested` trip, transitioning it to `accepted`.
- **Allowed Actor**: Authenticated Customer with an `approved` driver profile (`role = 'customer'`, `driver_profiles.status = 'approved'`).
- **Authorization**: Caller `jwt.sub` must match a driver profile. Caller cannot be the passenger on the trip (`passenger_id != driver_id`).
- **Headers**:
  - `Authorization: Bearer <token>` (Required)
  - `Idempotency-Key: <uuid/string>` (Required)
- **Path Parameters**:
  - `id`: UUID of the trip to accept.
- **Request Body**:
  ```json
  {
    "vehicle_id": "018d3f62-3333-7b3e-8c42-5f69a1e09333"
  }
  ```
- **Validation Rules**:
  - `vehicle_id`: Valid UUID string. Must belong to `driver_id` and have `status = 'approved'`.
- **Business Logic & Concurrency Semantics (NFR5, BR4, BR5, BR6)**:
  - Inside a single atomic transaction:
    1. Verifies driver profile is `approved`.
    2. Verifies `vehicle_id` belongs to driver (`vehicles.driver_id == jwt.sub`) and `vehicles.status == 'approved'`.
    3. Verifies driver has no other active trip (enforced by DB partial unique index `trips(driver_id)`).
    4. Verifies vehicle has no other active trip (enforced by DB partial unique index `trips(vehicle_id)`).
    5. Executes conditional status update: `UPDATE trips SET status = 'accepted', driver_id = $driver, vehicle_id = $vehicle, accepted_at = now() WHERE id = $id AND status = 'requested' RETURNING *;`.
  - If another driver won the acceptance race, or the trip is no longer `requested`, the query affects 0 rows, and the API returns `409 Conflict` (`TRIP_ALREADY_ACCEPTED`).
  - An identical retry with the same `Idempotency-Key` returns the stored accepted response without error.
- **Success Response**: `200 OK`
  ```json
  {
    "data": {
      "id": "018d3f62-7b1a-7b3e-8c42-5f69a1e09101",
      "passenger_id": "018d3f62-1111-7b3e-8c42-5f69a1e09111",
      "driver_id": "018d3f62-2222-7b3e-8c42-5f69a1e09222",
      "vehicle_id": "018d3f62-3333-7b3e-8c42-5f69a1e09333",
      "status": "accepted",
      "fare_minor": 450000,
      "currency": "NGN",
      "payment_method": "cash",
      "requested_at": "2026-10-26T12:00:00.000Z",
      "accepted_at": "2026-10-26T12:02:15.000Z",
      "driver_arriving_at": null,
      "started_at": null,
      "completed_at": null,
      "cancelled_at": null,
      "cancellation_reason": null,
      "expired_at": null,
      "created_at": "2026-10-26T12:00:00.000Z",
      "updated_at": "2026-10-26T12:02:15.000Z"
    }
  }
  ```

---

### 3.3 R3 — Passenger or Driver Retrieves Trip Details and Progress

- **Method & Path**: `GET /v1/trips/{id}`
- **Purpose**: Returns the full trip aggregate, including route, fare snapshot, participant summaries, latest telemetry sample, payment status, and review state.
- **Allowed Actor**: The trip's passenger, the assigned driver, or an Admin.
- **Authorization**:
  - Caller `jwt.sub` must equal `trips.passenger_id` OR `trips.driver_id` OR `jwt.role == 'admin'`.
  - Unrelated customers receive `404 Not Found` (strict ID masking).
- **Headers**:
  - `Authorization: Bearer <token>` (Required)
- **Path Parameters**:
  - `id`: UUID of the trip.
- **Success Response**: `200 OK`
  ```json
  {
    "data": {
      "id": "018d3f62-7b1a-7b3e-8c42-5f69a1e09101",
      "passenger_id": "018d3f62-1111-7b3e-8c42-5f69a1e09111",
      "driver_id": "018d3f62-2222-7b3e-8c42-5f69a1e09222",
      "vehicle_id": "018d3f62-3333-7b3e-8c42-5f69a1e09333",
      "status": "in_progress",
      "pickup_latitude": 6.524379,
      "pickup_longitude": 3.379206,
      "dropoff_latitude": 6.601838,
      "dropoff_longitude": 3.351486,
      "pickup_address": "Commercial Avenue, Yaba, Lagos",
      "dropoff_address": "Ikeja City Mall, Alausa, Ikeja",
      "fare_minor": 450000,
      "currency": "NGN",
      "payment_method": "cash",
      "requested_at": "2026-10-26T12:00:00.000Z",
      "accepted_at": "2026-10-26T12:02:15.000Z",
      "driver_arriving_at": "2026-10-26T12:05:00.000Z",
      "started_at": "2026-10-26T12:07:30.000Z",
      "completed_at": null,
      "cancelled_at": null,
      "cancellation_reason": null,
      "expired_at": null,
      "created_at": "2026-10-26T12:00:00.000Z",
      "updated_at": "2026-10-26T12:07:30.000Z",
      "passenger": {
        "id": "018d3f62-1111-7b3e-8c42-5f69a1e09111",
        "full_name": "Ada Lovelace"
      },
      "driver": {
        "id": "018d3f62-2222-7b3e-8c42-5f69a1e09222",
        "full_name": "Chidi Anagonye"
      },
      "vehicle": {
        "id": "018d3f62-3333-7b3e-8c42-5f69a1e09333",
        "make": "Toyota",
        "model": "Corolla",
        "color": "Silver",
        "license_plate": "LAG-123AA"
      },
      "latest_location": {
        "latitude": 6.551200,
        "longitude": 3.365400,
        "recorded_at": "2026-10-26T12:12:00.000Z"
      },
      "payment_summary": {
        "status": "pending",
        "attempt_count": 0,
        "succeeded_at": null
      },
      "review_summary": {
        "reviewed": false,
        "review_id": null
      }
    }
  }
  ```

---

### 3.4 Supporting Lifecycle Endpoints for R3 / Progress Transition

#### 3.4.1 Append Location Telemetry Sample (R3.4)
- **Method & Path**: `POST /v1/trips/{id}/locations`
- **Purpose**: Appends an immutable GPS coordinate sample for an active trip.
- **Allowed Actor**: Assigned driver only (`trips.driver_id == jwt.sub`).
- **Headers**:
  - `Authorization: Bearer <token>` (Required)
  - *(Note: `Idempotency-Key` is explicitly excluded to prevent storage bloat on 3–5s streaming pings. Telemetry relies on device-reported `recorded_at` and database `id` for retrieval and deterministic ordering; sample-level deduplication is not enforced, and repeated submissions may create duplicate rows).*
- **Validation**: Trip must be active (`accepted`, `driver_arriving`, `in_progress`). Latitude, longitude, optional accuracy, recorded timestamp.
- **Response**: `201 Created` returning the created telemetry record.

#### 3.4.2 Driver Marks Arrival
- **Method & Path**: `POST /v1/trips/{id}/arrive`
- **Purpose**: Transitions trip from `accepted` to `driver_arriving`. Sets `driver_arriving_at = now()`.
- **Allowed Actor**: Assigned driver only.

#### 3.4.3 Driver Starts Trip
- **Method & Path**: `POST /v1/trips/{id}/start`
- **Purpose**: Transitions trip from `driver_arriving` to `in_progress`. Sets `started_at = now()`.
- **Allowed Actor**: Assigned driver only.

#### 3.4.4 Cancel Trip
- **Method & Path**: `POST /v1/trips/{id}/cancel`
- **Purpose**: Transitions trip from `requested`, `accepted`, or `driver_arriving` to terminal `cancelled`. Sets `cancelled_at = now()` and stores optional `cancellation_reason`.
- **Allowed Actor**: Trip passenger or assigned driver (cancellation after `in_progress` is strictly forbidden).

---

### 3.5 R4 — Driver Completes Trip and Records Payment Outcome

- **Method & Path**: `POST /v1/trips/{id}/complete`
- **Purpose**: Transitions trip from `in_progress` to terminal `completed`, sets `completed_at`, and records the initial payment collection outcome.
- **Allowed Actor**: Assigned driver only (`trips.driver_id == jwt.sub`).
- **Authorization**: Caller must be the assigned driver. Trip must currently have `status = 'in_progress'`.
- **Headers**:
  - `Authorization: Bearer <token>` (Required)
  - `Idempotency-Key: <uuid/string>` (Required)
- **Path Parameters**:
  - `id`: UUID of the trip to complete.
- **Request Body**:
  ```json
  {
    "cash_collected": true
  }
  ```
  *(For `payment_method = 'electronic'`, `cash_collected` is null/omitted; the system triggers electronic settlement simulation).*
- **Business Logic & State Invariants (BR9, BR15, BR17, R4.1–R4.8)**:
  - Inside a single atomic transaction:
    1. Verifies caller is assigned driver and `trips.status == 'in_progress'`.
    2. Updates trip status to `completed`, sets `completed_at = now()`.
    3. Confirms payment method matches `trips.payment_method`.
    4. Records payment attempt in `payments` with `attempt_no = 1`, `amount_minor = trips.fare_minor`, `currency = trips.currency`, and `method = trips.payment_method`:
       - If `payment_method == 'cash'` and `cash_collected == true`: records `status = 'succeeded'`, `settled_at = now()`, `provider_reference = null`.
       - If `payment_method == 'electronic'`: records initial attempt with simulated provider outcome (`succeeded`, `failed`, or `pending`).
    5. Partial unique index `payments(trip_id) WHERE status = 'succeeded'` guarantees at-most-one successful collection ever settles for the trip.
    6. If electronic collection fails, trip completion is **not** rolled back (R4.7); trip remains `completed` with a `failed` payment attempt available for retry.
- **Success Response**: `200 OK`
  ```json
  {
    "data": {
      "trip": {
        "id": "018d3f62-7b1a-7b3e-8c42-5f69a1e09101",
        "status": "completed",
        "fare_minor": 450000,
        "currency": "NGN",
        "payment_method": "cash",
        "started_at": "2026-10-26T12:07:30.000Z",
        "completed_at": "2026-10-26T12:35:00.000Z"
      },
      "payment": {
        "id": "018d3f62-5555-7b3e-8c42-5f69a1e09555",
        "trip_id": "018d3f62-7b1a-7b3e-8c42-5f69a1e09101",
        "attempt_no": 1,
        "method": "cash",
        "amount_minor": 450000,
        "currency": "NGN",
        "status": "succeeded",
        "provider_reference": null,
        "failure_code": null,
        "settled_at": "2026-10-26T12:35:00.000Z",
        "created_at": "2026-10-26T12:35:00.000Z"
      }
    }
  }
  ```

#### 3.5.1 Electronic Payment Retry Endpoint
- **Method & Path**: `POST /v1/trips/{id}/payments/retry`
- **Purpose**: Creates a new payment attempt row (`attempt_no = N+1`) for a completed trip whose prior electronic attempts failed.
- **Allowed Actor**: Assigned driver, passenger, or system actor.
- **Invariants**: Rejected with `409 Conflict` (`PAYMENT_ALREADY_SUCCEEDED`) if any attempt row has `status = 'succeeded'`.

---

### 3.6 R5 — Passenger Reviews Their Own Completed Trip

- **Method & Path**: `POST /v1/trips/{id}/reviews`
- **Purpose**: Submits an immutable 1–5 star rating and optional text review for a completed trip.
- **Allowed Actor**: The customer who booked the trip as passenger (`trips.passenger_id == jwt.sub`).
- **Authorization**: Non-passengers are rejected with `403 Forbidden` or `404 Not Found`. Drivers cannot review trips they drove.
- **Headers**:
  - `Authorization: Bearer <token>` (Required)
  - `Idempotency-Key: <uuid/string>` (Required)
- **Path Parameters**:
  - `id`: UUID of the completed trip.
- **Request Body**:
  ```json
  {
    "rating": 5,
    "comment": "Driver arrived quickly and was very polite. Smooth ride!"
  }
  ```
- **Validation Rules**:
  - `rating`: Integer strictly between `1` and `5` inclusive.
  - `comment`: Optional string, max 2000 characters.
- **Business Logic & State Invariants (BR10, BR11, R5.1–R5.7)**:
  - Trip must currently have `status = 'completed'` and `driver_id IS NOT NULL`. If trip is not completed, returns `422 Unprocessable Entity` (`TRIP_NOT_COMPLETED`).
  - Verifies no review exists for this trip (`reviews.trip_id` is unique). If a review exists, returns `409 Conflict` (`DUPLICATE_REVIEW`).
  - Inserts review record. The reviewed driver is not stored in `reviews`; it is relationally derived from `trips.driver_id` (Decision D4).
  - Reviews are immutable: no `PUT`, `PATCH`, or `DELETE` endpoints exist for reviews.
- **Success Response**: `201 Created`
  ```json
  {
    "data": {
      "id": "018d3f62-6666-7b3e-8c42-5f69a1e09666",
      "trip_id": "018d3f62-7b1a-7b3e-8c42-5f69a1e09101",
      "passenger_id": "018d3f62-1111-7b3e-8c42-5f69a1e09111",
      "driver_id": "018d3f62-2222-7b3e-8c42-5f69a1e09222",
      "rating": 5,
      "comment": "Driver arrived quickly and was very polite. Smooth ride!",
      "created_at": "2026-10-26T12:40:00.000Z"
    }
  }
  ```

---

## 4. Query, Filter, Sort, and List Specifications

To adhere strictly to NFR6 (performance indexing) and avoid unindexed full-table scans, only explicitly indexed list queries are exposed:

### 4.1 Driver Queue — Available Trip Requests (`R2`)
- **Method & Path**: `GET /v1/trips/queue`
- **Purpose**: Lists unassigned trips in `requested` status waiting for driver acceptance, ordered FIFO.
- **Allowed Actor**: Approved drivers only.
- **Query Parameters**:
  - `limit`: Integer (Default 20, max 50).
- **Underlying Index**: Partial B-tree `trips(created_at ASC) WHERE status = 'requested'`.
- **Query**: `SELECT * FROM trips WHERE status = 'requested' ORDER BY created_at ASC LIMIT $1`.

### 4.2 Passenger Trip History (`R1`, `R3`)
- **Method & Path**: `GET /v1/passengers/me/trips`
- **Purpose**: Lists trips requested by the authenticated passenger with reverse-chronological pagination.
- **Allowed Actor**: Authenticated passenger (`jwt.sub`).
- **Query Parameters**:
  - `status`: Optional filter (`requested` | `accepted` | `driver_arriving` | `in_progress` | `completed` | `cancelled` | `expired`).
  - `limit`: Integer (Default 20, max 100).
  - `cursor`: Base64 encoded keyset cursor `(created_at, id)`.
- **Underlying Index**: `trips(passenger_id, created_at DESC)`.

### 4.3 Driver Trip History (`R2`, `R3`)
- **Method & Path**: `GET /v1/drivers/me/trips`
- **Purpose**: Lists trips assigned to the authenticated driver.
- **Allowed Actor**: Approved driver (`jwt.sub`).
- **Query Parameters**: `status`, `limit`, `cursor`.
- **Underlying Index**: `trips(driver_id, created_at DESC)`.

### 4.4 Driver Vehicle List (`R2`)
- **Method & Path**: `GET /v1/drivers/me/vehicles`
- **Purpose**: Lists vehicles owned by the authenticated driver to choose from during acceptance.
- **Allowed Actor**: Approved driver.
- **Underlying Index**: `vehicles(driver_id, status)`.

---

## 5. Architectural Analyses: REST vs. GraphQL & Real-Time Telemetry

### 5.1 REST vs. GraphQL: Over-Fetching Analysis

#### 5.1.1 Problem Statement & Comparative Example
Consider a mobile passenger home screen displaying "Active Trip Card". The UI requires only 4 fields: `status`, `driver.full_name`, `vehicle.license_plate`, and `latest_location`.

**Representative REST Response (`GET /v1/trips/{id}`)**:
```json
{
  "data": {
    "id": "018d3f62-7b1a-7b3e-8c42-5f69a1e09101",
    "passenger_id": "018d3f62-1111-7b3e-8c42-5f69a1e09111",
    "driver_id": "018d3f62-2222-7b3e-8c42-5f69a1e09222",
    "vehicle_id": "018d3f62-3333-7b3e-8c42-5f69a1e09333",
    "status": "in_progress",
    "pickup_latitude": 6.524379,
    "pickup_longitude": 3.379206,
    "dropoff_latitude": 6.601838,
    "dropoff_longitude": 3.351486,
    "pickup_address": "Commercial Avenue, Yaba, Lagos",
    "dropoff_address": "Ikeja City Mall, Alausa, Ikeja",
    "fare_minor": 450000,
    "currency": "NGN",
    "payment_method": "cash",
    "requested_at": "2026-10-26T12:00:00.000Z",
    "accepted_at": "2026-10-26T12:02:15.000Z",
    "driver_arriving_at": "2026-10-26T12:05:00.000Z",
    "started_at": "2026-10-26T12:07:30.000Z",
    "completed_at": null,
    "cancelled_at": null,
    "cancellation_reason": null,
    "expired_at": null,
    "created_at": "2026-10-26T12:00:00.000Z",
    "updated_at": "2026-10-26T12:07:30.000Z",
    "passenger": { "id": "018d3f62-1111...", "full_name": "Ada Lovelace" },
    "driver": { "id": "018d3f62-2222...", "full_name": "Chidi Anagonye" },
    "vehicle": {
      "id": "018d3f62-3333...",
      "make": "Toyota",
      "model": "Corolla",
      "color": "Silver",
      "license_plate": "LAG-123AA"
    },
    "latest_location": {
      "latitude": 6.551200,
      "longitude": 3.365400,
      "recorded_at": "2026-10-26T12:12:00.000Z"
    },
    "payment_summary": { "status": "pending", "attempt_count": 0, "succeeded_at": null },
    "review_summary": { "reviewed": false, "review_id": null }
  }
}
```
*Payload Size*: ~1,450 bytes. The client discards 75% of the returned JSON attributes (coordinates, fare details, timestamps, sub-summaries).

**Equivalent GraphQL Query**:
```graphql
query GetActiveTripSummary($tripId: UUID!) {
  trip(id: $tripId) {
    status
    driver {
      fullName
    }
    vehicle {
      licensePlate
    }
    latestLocation {
      latitude
      longitude
    }
  }
}
```
**GraphQL Response**:
```json
{
  "data": {
    "trip": {
      "status": "in_progress",
      "driver": { "fullName": "Chidi Anagonye" },
      "vehicle": { "licensePlate": "LAG-123AA" },
      "latestLocation": { "latitude": 6.551200, "longitude": 3.365400 }
    }
  }
}
```
*Payload Size*: ~210 bytes (85% bandwidth reduction).

#### 5.1.2 Evaluation & Architecture Decision for RideFlow MVP
- **Does GraphQL belong in the RideFlow MVP?** **No.**
- **Justification**:
  1. **Strict Core Workflows**: RideFlow MVP comprises exactly 5 core transactional actions (R1–R5) with predictable payload patterns.
  2. **Security & Object-Level Authorization Overhead**: GraphQL introduces arbitrary depth and execution path complexities, making fine-grained object-level authorization (verifying caller is assigned passenger or driver for each nested node) substantially harder to enforce reliably than discrete REST endpoints.
  3. **HTTP Caching and Idempotency**: REST aligns natively with HTTP caching headers (`ETag`, `Cache-Control`) and explicit `Idempotency-Key` tracking on HTTP `POST` verbs.
  4. **Complexity vs. ROI**: For mobile over-fetching, sparse REST fieldsets (`GET /v1/trips/{id}?fields=status,driver.full_name,vehicle.license_plate`) achieve identical bandwidth savings without requiring a GraphQL runtime, schema federation, or query complexity analysis.

---

### 5.2 Real-Time Trip Progress: SSE vs. WebSockets

#### 5.2.1 Problem Analysis
In Action R3, the passenger must observe real-time updates as the assigned driver approaches and executes the trip:
1. Status changes: `accepted -> driver_arriving -> in_progress -> completed`.
2. Driver telemetry: GPS updates arriving every 3–5 seconds.

#### 5.2.2 Technology Comparison
| Dimension | Server-Sent Events (SSE) | WebSockets (WS) |
|---|---|---|
| **Communication Direction** | Unidirectional: Server-to-Client | Full-Duplex: Bidirectional |
| **Protocol Layer** | Standard HTTP/2 or HTTP/1.1 | TCP upgraded handshake (`ws://`, `wss://`) |
| **Firewall & Proxy Traversal** | Seamless; operates over standard HTTPS port 443 | Frequently blocked or abruptly dropped by corporate firewalls/cellular proxies |
| **Native Reconnection** | Built-in browser/client auto-reconnection with `Last-Event-ID` | Manual heartbeat, ping/pong, and reconnection logic required |
| **Authentication** | Standard HTTP headers (`Authorization: Bearer <token>`) | Non-standard auth during upgrade handshake; query params often misused |
| **Complexity & Overhead** | Low; minimal state on standard reverse proxy (e.g. Nginx, Envoy) | High; requires dedicated persistent socket cluster and stateful gateway |

#### 5.2.3 Architecture Decision for RideFlow
- **Architectural Position**: **Server-Sent Events (SSE)** is selected as the designated future real-time streaming pattern for passenger trip progress (e.g. proposed endpoint `GET /v1/trips/{id}/stream`).
- **MVP Contract Scope**: As established in the assessment scope, **no streaming endpoint or live streaming infrastructure is currently specified as part of the Stage 4 MVP contract (`docs/openapi.yaml`)**. In the MVP, passenger clients retrieve current trip status and the latest location sample using the standard REST endpoint `GET /v1/trips/{id}`.
- **Justification for Future SSE Adoption**:
  - **Unidirectional Match**: During an active trip, the passenger client is strictly a *consumer* of driver updates (status changes and GPS telemetry). The passenger does not send continuous streaming data back to the server.
  - **Standard HTTP Alignment**: SSE operates over standard HTTP/2, allowing token authentication via standard `Authorization: Bearer` headers, seamless proxying, multiplexing over a single connection, and native client retry semantics via `Last-Event-ID`.
  - **Decoupled Telemetry Ingestion**: The assigned driver appends location updates via discrete HTTP `POST /v1/trips/{id}/locations` requests. Decoupling ingestion (driver HTTP POST) from fanout (future passenger SSE stream) ensures authorization and persistence guarantees remain cleanly isolated.

---

## 6. Edge Cases & Failure Scenarios Matrix

| Edge Case Scenario | Condition | HTTP Status | Error Code | System Behavior & Mitigation |
|---|---|---|---|---|
| **Concurrent Trip Acceptance** | Two drivers attempt to accept the same `requested` trip simultaneously. | `200 OK` (Winner)<br>`409 Conflict` (Loser) | `TRIP_ALREADY_ACCEPTED` | Winning driver executes atomic conditional update `WHERE status = 'requested'`. Losing driver affects 0 rows, rolls back, and receives clean conflict message. |
| **Active Passenger Limit (BR3)** | Passenger requests trip while holding a trip in `in_progress`. | `409 Conflict` | `ACTIVE_TRIP_CONFLICT` | Checked at API layer and enforced by DB partial unique index `trips(passenger_id) WHERE status IN (active)`. |
| **Ineligible Driver Acceptance** | Driver profile is `suspended` or selected vehicle is not `approved`. | `422 Unprocessable Entity` | `INELIGIBLE_DRIVER` | Precondition check inside acceptance transaction validates `driver_profiles.status` and `vehicles.status`. |
| **Unauthorized Trip Read (BOLA)** | Customer B attempts `GET /v1/trips/{id}` for Customer A's trip. | `404 Not Found` | `RESOURCE_NOT_FOUND` | System returns 404 to avoid leaking whether the trip UUID exists in the system. |
| **Out-of-Order Transition** | Driver attempts to complete a trip that is currently `accepted` (skipping arrival and start). | `409 Conflict` | `INVALID_STATE_TRANSITION` | Rejected by state transition rules; completion requires `in_progress` status. |
| **Electronic Payment Failure** | External payment provider simulates timeout or decline during trip completion. | `200 OK` (Trip completes with failed payment) | N/A | Trip status transitions to `completed`; payment attempt row is recorded with `status = 'failed'`. Completion is not rolled back (R4.7). |
| **Duplicate Idempotency Key with Different Payload** | Client submits same `Idempotency-Key` with altered coordinates or fare. | `409 Conflict` | `IDEMPOTENCY_CONFLICT` | SHA-256 fingerprint mismatch detected; request is aborted with no database mutation. |
| **Premature Review Attempt** | Passenger attempts to submit review while trip is still `in_progress`. | `422 Unprocessable Entity` | `TRIP_NOT_COMPLETED` | Review insertion requires `trips.status == 'completed'`. |
| **Duplicate Review Attempt** | Passenger attempts second review on their completed trip. | `409 Conflict` | `DUPLICATE_REVIEW` | Enforced by unique constraint on `reviews.trip_id`. |
| **Malformed UUID or Out-of-Range Coordinates** | Latitude supplied as `105.00` or UUID has invalid characters. | `400 Bad Request` | `VALIDATION_ERROR` | Request validation fails immediately at the gateway layer before invoking domain logic. |

---

## 7. Requirement and Business Rule Traceability Matrix

| Requirement / Rule | Description | Enforcing Endpoint(s) | Contract Section |
|---|---|---|---|
| **R1 / R1.1–R1.7** | Passenger requests trip with server fare snapshot | `POST /v1/trips` | Section 3.1 |
| **R2 / R2.1–R2.7** | Eligible driver atomically accepts trip with approved vehicle | `POST /v1/trips/{id}/accept` | Section 3.2 |
| **R3 / R3.1–R3.7** | Authorized participant retrieves current trip details & progress | `GET /v1/trips/{id}` | Section 3.3 |
| **R4 / R4.1–R4.8** | Driver completes trip & records payment outcome | `POST /v1/trips/{id}/complete` | Section 3.5 |
| **R5 / R5.1–R5.7** | Passenger reviews completed trip | `POST /v1/trips/{id}/reviews` | Section 3.6 |
| **BR1, BR2** | Exactly one passenger, max one assigned driver/vehicle | `POST /v1/trips`, `POST /v1/trips/{id}/accept` | Sections 3.1, 3.2 |
| **BR3, BR4, BR5** | Per-capacity single active trip limit | `POST /v1/trips`, `POST /v1/trips/{id}/accept` | Sections 3.1, 3.2 |
| **BR6** | Driver and vehicle approval eligibility checks | `POST /v1/trips/{id}/accept` | Section 3.2 |
| **BR9, BR15** | At most one successful payment; fare/currency snapshot equality | `POST /v1/trips/{id}/complete` | Section 3.5 |
| **BR10, BR11** | At most one immutable review for completed trip by passenger | `POST /v1/trips/{id}/reviews` | Section 3.6 |
| **NFR2, D9** | Object-level authorization; UUID secrecy is not security | All `/v1/*` endpoints | Section 2.3 |
| **NFR3, A1, A2** | Minor currency units, ISO 4217, integer arithmetic | `POST /v1/trips`, `POST /v1/trips/{id}/complete` | Sections 2.2, 3.1, 3.5 |
| **NFR4** | Append-only auditability | All mutating endpoints | Sections 3.1–3.6 |
| **NFR5** | Concurrency control & conflict returns | `POST /v1/trips/{id}/accept` | Section 3.2 |
| **NFR6** | Bounded index-backed list queries & pagination | `GET /v1/trips/queue`, `GET /v1/*/trips` | Section 4 |
| **NFR7** | Standard envelopes, RFC 7807 errors, Idempotency-Key | All `/v1/*` endpoints | Sections 2.4, 2.5, 2.6 |
