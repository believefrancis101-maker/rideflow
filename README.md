# RideFlow — API Design, Data Modeling & Database Proof

[![PostgreSQL 16](https://img.shields.io/badge/PostgreSQL-16--alpine-336791?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![OpenAPI 3.1](https://img.shields.io/badge/OpenAPI-3.1.0-85EA2D?logo=openapi-initiative&logoColor=black)](docs/openapi.yaml)
[![Docker](https://img.shields.io/badge/Docker-Verified_Isolated_Proof-2496ED?logo=docker&logoColor=white)](database/run_proof.ps1)
[![PowerShell](https://img.shields.io/badge/PowerShell-Automated_Runner-5391FE?logo=powershell&logoColor=white)](database/run_proof.ps1)

> **RideFlow** is an architectural specification, formal data model, and database proof for an on-demand ride-hailing platform connecting passengers, drivers, and vehicles with telemetry tracking, dispatch queues, payment settlement, and ratings.

This repository contains the completed deliverables for **Task 3: API Design and Data Modeling**. It establishes the pre-implementation engineering foundation — business workflows, 3NF relational modeling, formal state machines, OpenAPI 3.1 contract specifications, and reproducible PostgreSQL 16 database verification — before application code is written.

---

## Scope & Implementation Boundaries

### In Scope (Completed & Tracked)
* **Requirements & Invariants**: Problem statement, 5 core user actions (R1–R5), 17 business rules (BR1–BR17), 9 non-functional requirements (NFR1–NFR9), assumptions, and constraints.
* **3NF Data Model**: 9 domain tables using synthetic UUID primary keys (`gen_random_uuid()`), integer minor units for monetary amounts (`BIGINT fare_minor`, `VARCHAR(3) currency`), ISO 8601 UTC timestamps, and soft-delete semantics on users.
* **Database Implementation**: Forward-only PostgreSQL 16 migrations (`001`–`004`) establishing partial unique indexes, composite foreign keys, and PL/pgSQL triggers for state-machine transition enforcement and record immutability.
* **Deterministic Seed Data**: 44 users (9 named, 35 synthetic), 4 drivers, 4 vehicles, and 38 trips with associated telemetry samples, payments, and reviews.
* **API Contract Modeling**: OpenAPI 3.1 specification (`docs/openapi.yaml`) defining typed payloads, custom structured error envelopes, cursor pagination, and SHA-256 idempotency key semantics.
* **Architectural Trade-Off Analyses**: REST vs. GraphQL over-fetching evaluation (with defined evaluation hypotheses) and Server-Sent Events (SSE) vs. WebSockets streaming comparison.
* **Automated Database Proof**: Self-contained runner script (`database/run_proof.ps1`) executing all migrations, seed ingestion, action queries, `EXPLAIN` query plans, and constraint violation tests against an isolated PostgreSQL container.
* **Defence Dossier & Engineering Post**: Thorough answers to mandatory technical defence questions and a systems engineering article on state machine terminality.

### Explicitly Out of Scope
* **Application API Server**: A running HTTP API server runtime (such as Express, FastAPI, or Go Gin) is not implemented. All API designs are documented contract specifications.
* **Frontend Applications**: Passenger or driver user interfaces (web or mobile) are not implemented.
* **Identity Provider**: Authentication is modeled at the contract boundary via HTTP Bearer tokens (`Authorization: Bearer <jwt>`). External identity token issuance, password storage, and OAuth2/OIDC servers are outside the database proof.

---

## Technologies Actually Used

* **Database Engine**: [PostgreSQL 16](https://www.postgresql.org/) (`postgres:16-alpine` executed via Docker).
* **Database Procedural Language**: PL/pgSQL (for state-machine transition guard triggers, automatic timestamp updates, and append-only record immutability).
* **Containerization**: [Docker Engine](https://www.docker.com/) / Docker Desktop (providing isolated database execution without modifying host system configurations).
* **Proof Automation**: [PowerShell](https://github.com/PowerShell/PowerShell) (PowerShell script orchestrating Docker lifecycle, schema migration, seed loading, SQL execution, and evidence collection).
* **API Specification Format**: [OpenAPI 3.1.0](https://spec.openapis.org/oas/v3.1.0) (authored directly in YAML; formal automated linter/validator execution was not part of the database assessment).
* **Diagrams & Documentation**: Mermaid.js and GitHub-Flavored Markdown.
* **Version Control**: Git.

*(No application-tier runtimes such as Node.js, Python, or Go are required or used in this repository; all verification executes natively in PostgreSQL 16).*

---

## Repository Structure

```text
rideflow/
├── README.md                               # Repository overview, navigation & proof runner guide
├── docs/                                   # Architectural specifications & dossiers
│   ├── submission-index.md                 # Master navigation index & grading rubric alignment
│   ├── requirements.md                     # Step 1: Requirements, personas, actions & NFRs
│   ├── data-model.md                       # Step 2: Entity dictionary, data types & constraints
│   ├── er-diagram.md                       # Step 2: Mermaid logical ERD (9 entities)
│   ├── design-decisions.md                 # Step 3: Seven hard questions & index strategy
│   ├── state-machines.md                   # Step 3: Trip, payment & driver formal state machines
│   ├── api-design.md                       # Step 4: Endpoint contracts, GraphQL & SSE analyses
│   ├── openapi.yaml                        # Step 4: OpenAPI 3.1 specification (YAML)
│   ├── defence-dossier.md                  # Stage 6: Answers to mandatory defence questions
│   ├── engineering-post.md                 # Stage 6: Senior engineering post on state machines
│   └── evidence-package.md                 # Stage 6: Mermaid ERD, query plans & terminal outputs
├── database/                               # Database implementation & proof suite
│   ├── migrations/                         # Step 5: Forward-only PostgreSQL 16 migrations
│   │   ├── 001_initial_schema.sql          # Users, driver profiles, vehicles
│   │   ├── 002_trips_and_telemetry.sql     # Trips, location samples, composite FK
│   │   ├── 003_payments_reviews_audit_idempotency.sql # Payments, reviews, audit, idempotency
│   │   └── 004_indexes_and_triggers.sql    # Partial unique indexes & PL/pgSQL triggers
│   ├── seeds/                              # Step 5: Deterministic test dataset
│   │   └── 01_mvp_seed_data.sql            # 44 users, 4 drivers, 4 vehicles, 38 trips
│   ├── queries/                            # Step 5: Five core user actions (R1–R5)
│   │   ├── q1_request_trip.sql             # R1: Rider requests trip
│   │   ├── q2_accept_trip.sql              # R2: Driver accepts oldest requested trip
│   │   ├── q3_trip_progress.sql            # R3: In-flight telemetry & progress inspection
│   │   ├── q4_complete_trip.sql            # R4: Driver completes trip & settles payment
│   │   └── q5_review_trip.sql              # R5: Rider submits review for completed trip
│   ├── tests/                              # Step 5: Constraint and invariant test suite
│   │   ├── invalid_insert_1_passenger.sql  # Negative Test: Second active trip for passenger
│   │   ├── invalid_insert_2_payment.sql    # Negative Test: Second successful payment for trip
│   │   ├── invalid_insert_3_review.sql     # Negative Test: Second review for trip
│   │   ├── test_cross_driver_vehicle.sql   # Invariant Test: Cross-driver vehicle composite FK
│   │   ├── test_forbidden_transition.sql   # Invariant Test: Illegal terminal status transition
│   │   ├── test_append_only_mutation.sql   # Invariant Test: Review and audit immutability
│   │   ├── test_payment_failure_non_undo.sql # Invariant Test: Payment failure non-undo rule
│   │   └── test_telemetry_lifecycle.sql    # Invariant Test: Telemetry purge vs audit retention
│   └── run_proof.ps1                       # Automated reproducible proof runner script
└── evidence/                               # Step 5: Verified PostgreSQL execution logs
    ├── 01_migration_log.txt                # Forward-only migration apply logs
    ├── 02_schema_inspection.txt            # PostgreSQL \dt+, \di+, \d+ catalog inspection
    ├── 03_seed_log.txt                     # Seed execution output
    ├── 04_q1_to_q5_results.txt             # Actions R1–R5 sequential execution results
    ├── 05_explain_q2_queue.txt             # EXPLAIN (ANALYZE, BUFFERS) for Action R2 queue
    ├── 06_explain_q3_progress.txt          # EXPLAIN (ANALYZE, BUFFERS) for Action R3 progress
    ├── 07_rejected_insert_1_passenger.txt  # SQLSTATE 23505 log for passenger concurrency
    ├── 08_rejected_insert_2_payment.txt    # SQLSTATE 23505 log for payment concurrency
    ├── 09_rejected_insert_3_review.txt     # SQLSTATE 23505 log for duplicate review
    └── 10_additional_tests.txt             # Cross-driver FK, transitions & immutability logs
```

---

## Core Documentation Quick Links

| Document | Focus & Highlights |
|---|---|
| [**Submission Index**](docs/submission-index.md) | **Master navigation hub**: Requirements traceability matrix and "Pass vs. Excellent" rubric alignment. |
| [**Requirements Baseline**](docs/requirements.md) | Operational baseline: Personas, actions R1–R5, business rules BR1–BR17, and non-functional requirements. |
| [**Data Model Dictionary**](docs/data-model.md) | Complete 9-entity data dictionary, exact PostgreSQL types, nullability, defaults, and cardinalities. |
| [**Entity-Relationship Diagram**](docs/er-diagram.md) | Mermaid ERD illustrating primary keys, foreign keys, composite relationships, and cascades. |
| [**Design Decisions**](docs/design-decisions.md) | Answers to the 7 hard questions: Normalisation, money representation, time, UUIDs, constraints, and index strategy. |
| [**State Machines**](docs/state-machines.md) | Formal state machines for trips (7 states), payments (4 states), and drivers (3 states) with forbidden transition matrices. |
| [**API Design & Technology Analyses**](docs/api-design.md) | Endpoint contracts, custom structured error envelopes, REST vs. GraphQL evaluation, and SSE vs. WebSockets analysis. |
| [**OpenAPI 3.1 Contract**](docs/openapi.yaml) | OpenAPI 3.1 specification (YAML) covering actions R1–R5 with typed payloads and parameter models. |
| [**Defence Dossier**](docs/defence-dossier.md) | Rigorous technical answers to the four mandatory defence questions with line references and follow-up defenses. |
| [**Visual Evidence Package**](docs/evidence-package.md) | Mermaid ERD and state-machine diagrams, verbatim query plans, and raw constraint rejection logs. |
| [**Senior Engineering Post**](docs/engineering-post.md) | Architecture deep dive: *"The Terminal Trap: Why Electronic Payment Failures Must Never Undo Trip Completion"*. |

---

## Database Proof: Execution & Verification

The database schema, seed data, query plans, and constraint tests can be verified against a clean, isolated PostgreSQL 16 container using [`database/run_proof.ps1`](database/run_proof.ps1).

### Prerequisites
* [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed, running, and accessible from the shell.
* [PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) (Windows PowerShell 5.1 or PowerShell 7+ on macOS/Linux).

### Verified Safe Execution Command
From the root of the repository, execute:

```powershell
powershell -ExecutionPolicy Bypass -File database/run_proof.ps1
```

Or within an existing PowerShell session:

```powershell
.\database\run_proof.ps1
```

### Script Behavior & Isolation Safeguards
The proof runner script implements the following safeguards:
* **Port Isolation**: Maps the container port to host port **`5433`** by default (`-Port 5433`), avoiding collisions with local PostgreSQL instances on standard port `5432`.
* **Scoped Container Cleanup**: Targets specifically the container named **`rideflow-pg-proof`** (`-ContainerName rideflow-pg-proof`). Unrelated Docker containers on the host are never inspected, stopped, or removed.
* **Preservation Switch (`-PreserveExisting`)**: If a container named `rideflow-pg-proof` already exists, the script halts with an error if `-PreserveExisting` is passed (`Container rideflow-pg-proof already exists and PreserveExisting was requested. Aborting.`). When `-PreserveExisting` is false (default), it safely removes the prior `rideflow-pg-proof` container (`docker rm -f rideflow-pg-proof`) before spinning up a fresh one.
* **Readiness Polling**: Polls `pg_isready -U postgres -d rideflow` every 1 second (up to 30 seconds) until PostgreSQL accepts connections.
* **Output Capture**: Writes raw execution logs directly to the [`evidence/`](evidence/) directory, mirroring the committed evidence files.

### Script Parameter Reference
The script defines the following parameters in its `param` block:

| Parameter | Type | Default Value | Description |
|---|---|---|---|
| `-ContainerName` | `string` | `"rideflow-pg-proof"` | Name of the isolated Docker container. |
| `-Port` | `int` | `5433` | Host port mapped to container port 5432. |
| `-User` | `string` | `"postgres"` | Database user name. |
| `-Db` | `string` | `"rideflow"` | Database name. |
| `-Password` | `string` | `"postgres"` | Password for the local container database user. |
| `-EvidenceDir` | `string` | `"evidence"` | Relative path to directory receiving execution logs. |
| `-PreserveExisting` | `switch` | `$false` | When specified, aborts if the container already exists instead of recreating it. |

---

## Database Operations & Constraint Verification

The proof runner executes the schema migrations, populates the deterministic seed dataset, and verifies the following database operations and constraints:

### 1. Five Core User Actions (Sequential Execution)
* **Q1 (Request Trip)**: Inserts a new trip in `requested` status with agreed fare minor units and currency code, guarded by an active-passenger check.
* **Q2 (Accept Trip)**: Demonstrates atomic queue claiming where a driver selects the oldest requested trip using `FOR UPDATE SKIP LOCKED` and transitions it to `accepted`.
* **Q3 (In-Flight Progress & Telemetry)**: Executes a join query retrieving passenger details, driver details, vehicle information, and the latest sampled GPS coordinate via a lateral join on `trip_location_samples`.
* **Q4 (Complete Trip & Settle Payment)**: Transitions the trip to `completed` and inserts the completed payment row in a single atomic transaction.
* **Q5 (Review Trip)**: Inserts a passenger review and rating (1–5) linked to the completed trip.

### 2. Query Plan Performance Verification
* **Q2 Queue Query**: Index Scan on `trips_requested_queue_idx` (`status = 'requested'`, `created_at ASC`) executing in **0.050 ms** ([`evidence/05_explain_q2_queue.txt`](evidence/05_explain_q2_queue.txt)).
* **Q3 Progress Query**: Index Scan on `trips_pkey` with a lateral index scan on `trip_location_samples_lookup_idx` executing in **0.324 ms** ([`evidence/06_explain_q3_progress.txt`](evidence/06_explain_q3_progress.txt)).

### 3. Constraint & Negative Tests
* **Invalid Insert 1 (Active Passenger)**: Rejects an attempt to create a second concurrent active trip for a passenger via partial unique index `trips_active_passenger_idx` (**SQLSTATE 23505**).
* **Invalid Insert 2 (Duplicate Payment)**: Rejects an attempt to record a second successful payment for the same trip via partial unique index `payments_single_success_idx` (**SQLSTATE 23505**).
* **Invalid Insert 3 (Duplicate Review)**: Rejects an attempt to record a second review for the same trip via unique constraint `reviews_trip_id_key` (**SQLSTATE 23505**).
* **Cross-Driver Vehicle FK**: Enforces that a driver cannot complete a trip using a vehicle registered to another driver via composite foreign key `trips_driver_vehicle_fkey` on `vehicles(driver_id, id)` (**SQLSTATE 23503**).
* **Forbidden State Transition**: Enforces via PL/pgSQL trigger `fn_trips_state_machine()` that terminal trips (`completed`, `cancelled`) cannot be modified or regressed (**SQLSTATE 23514**).
* **Append-Only Immutability**: Proves via trigger `fn_immutable_record()` that completed reviews and audit log records cannot be updated or deleted (**SQLSTATE 23514**).
* **Payment Failure Non-Undo**: Proves that a failed payment attempt records a failure row without regressing trip completion, liberating driver availability and preventing vehicle lockup.
* **Telemetry Lifecycle**: Proves cascading purge on trip deletion while preserving payment and audit records for accounting compliance.

---

## Assumptions & Limitations

1. **Docker Requirement**: Reproducing the database proof requires an active Docker daemon. The runner manages container lifecycle automatically.
2. **Authentication Boundary**: Authentication is specified at the API contract layer via HTTP Bearer tokens (`Authorization: Bearer <jwt>`). External identity token issuance and password verification are assumed external; user roles (`customer`, `admin`) and identities are stored as UUID primary keys without storing passwords in the database schema.
3. **Telemetry Ingestion**: In-flight GPS coordinates are modeled relationally in `trip_location_samples` for auditability and query demonstration. In a production environment, high-frequency location pings would ingest through an in-memory stream (such as Redis Streams) before batching to persistent storage, as documented in [docs/design-decisions.md](docs/design-decisions.md).
