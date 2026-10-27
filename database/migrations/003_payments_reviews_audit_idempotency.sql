-- Migration 003: Payments, Reviews, Audit Events, Idempotency Keys
-- RideFlow Task 3 - PostgreSQL Migration

BEGIN;

-- Table: payments
CREATE TABLE payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE RESTRICT,
    attempt_no INTEGER NOT NULL CHECK (attempt_no > 0),
    method TEXT NOT NULL CHECK (method IN ('cash', 'electronic')),
    amount_minor BIGINT NOT NULL CHECK (amount_minor > 0),
    currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'succeeded', 'failed')),
    provider_reference TEXT NULL,
    failure_code TEXT NULL,
    settled_at TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Composite FK enforcing exact fare, currency, and payment method parity with trip
    CONSTRAINT payments_trip_fare_snapshot_fkey FOREIGN KEY (trip_id, amount_minor, currency, method)
        REFERENCES trips(id, fare_minor, currency, payment_method) ON DELETE RESTRICT,

    -- Sequence uniqueness per trip
    CONSTRAINT payments_trip_attempt_unique UNIQUE (trip_id, attempt_no),

    -- Settlement rules
    CONSTRAINT payments_settled_at_coherence CHECK (
        (status = 'pending' AND settled_at IS NULL) OR
        (status IN ('succeeded', 'failed') AND settled_at IS NOT NULL)
    ),

    -- Cash payment cannot have provider reference
    CONSTRAINT payments_cash_no_provider_ref CHECK (
        method <> 'cash' OR provider_reference IS NULL
    )
);

-- Table: reviews
CREATE TABLE reviews (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id UUID NOT NULL UNIQUE REFERENCES trips(id) ON DELETE RESTRICT,
    passenger_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    rating SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment TEXT NULL CHECK (comment IS NULL OR char_length(comment) <= 2000),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Composite FK enforcing that review author is strictly the passenger who took the trip
    CONSTRAINT reviews_trip_passenger_fkey FOREIGN KEY (trip_id, passenger_id)
        REFERENCES trips(id, passenger_id) ON DELETE RESTRICT
);

-- Table: audit_events
CREATE TABLE audit_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_type TEXT NOT NULL CHECK (actor_type IN ('customer', 'admin', 'system')),
    actor_user_id UUID NULL REFERENCES users(id) ON DELETE RESTRICT,
    action TEXT NOT NULL CHECK (char_length(action) BETWEEN 1 AND 100),
    entity_type TEXT NOT NULL CHECK (entity_type ~ '^[a-z][a-z0-9_]{0,63}$'),
    entity_id UUID NOT NULL,
    before_data JSONB NULL,
    after_data JSONB NULL,
    metadata JSONB NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- System actor has no user ID; customer/admin actor requires user ID
    CONSTRAINT audit_events_actor_coherence CHECK (
        (actor_type = 'system' AND actor_user_id IS NULL) OR
        (actor_type IN ('customer', 'admin') AND actor_user_id IS NOT NULL)
    )
);

-- Table: idempotency_keys
CREATE TABLE idempotency_keys (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    principal_user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    operation TEXT NOT NULL,
    key TEXT NOT NULL CHECK (char_length(key) BETWEEN 8 AND 255),
    request_hash TEXT NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    response_status SMALLINT NOT NULL CHECK (response_status BETWEEN 200 AND 599),
    response_body JSONB NOT NULL,
    resource_type TEXT NULL,
    resource_id UUID NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL CHECK (expires_at > created_at),

    -- At-most-once execution per principal, operation, and key
    CONSTRAINT idempotency_keys_principal_op_key_unique UNIQUE (principal_user_id, operation, key)
);

COMMIT;
