-- Migration 004: Indexes, State Machine, and Immutability Triggers
-- RideFlow Task 3 - PostgreSQL Migration

BEGIN;

-- ============================================================================
-- 1. INTEGRITY & CONCURRENCY ENFORCING INDEXES (PARTIAL UNIQUES)
-- ============================================================================

-- BR3: One active trip per passenger
CREATE UNIQUE INDEX trips_active_passenger_idx
    ON trips(passenger_id)
    WHERE status IN ('requested', 'accepted', 'driver_arriving', 'in_progress');

-- BR4: One active trip per driver
CREATE UNIQUE INDEX trips_active_driver_idx
    ON trips(driver_id)
    WHERE driver_id IS NOT NULL AND status IN ('requested', 'accepted', 'driver_arriving', 'in_progress');

-- BR5: One active trip per vehicle
CREATE UNIQUE INDEX trips_active_vehicle_idx
    ON trips(vehicle_id)
    WHERE vehicle_id IS NOT NULL AND status IN ('requested', 'accepted', 'driver_arriving', 'in_progress');

-- BR9: At most one successful payment collection per trip
CREATE UNIQUE INDEX payments_single_success_idx
    ON payments(trip_id)
    WHERE status = 'succeeded';

-- Electronic payment provider callback reference uniqueness
CREATE UNIQUE INDEX payments_provider_reference_idx
    ON payments(provider_reference)
    WHERE provider_reference IS NOT NULL;

-- ============================================================================
-- 2. LOOKUP PERFORMANCE & FOREIGN KEY SUPPORTING INDEXES
-- ============================================================================

-- R2: FIFO available requested trips queue
CREATE INDEX trips_requested_queue_idx
    ON trips(created_at ASC)
    WHERE status = 'requested';

-- R1 / R3: Passenger trip history & ownership lookups
CREATE INDEX trips_passenger_history_idx
    ON trips(passenger_id, created_at DESC);

-- R2 / R3: Driver assigned trip history lookups
CREATE INDEX trips_driver_history_idx
    ON trips(driver_id, created_at DESC);

-- R3: Latest location telemetry sample & history fetch
CREATE INDEX trip_location_samples_lookup_idx
    ON trip_location_samples(trip_id, recorded_at DESC, id DESC);

-- R2: Eligible vehicle check
CREATE INDEX vehicles_driver_status_idx
    ON vehicles(driver_id, status);

-- R2: Driver profile approval lookup
CREATE INDEX driver_profiles_status_idx
    ON driver_profiles(status);

-- R3 / R4: Payment history lookup
CREATE INDEX payments_trip_history_idx
    ON payments(trip_id, created_at DESC);

-- R5: Passenger review history lookup
CREATE INDEX reviews_passenger_history_idx
    ON reviews(passenger_id, created_at DESC);

-- NFR4: Entity audit history lookup
CREATE INDEX audit_events_entity_idx
    ON audit_events(entity_type, entity_id, created_at DESC);

-- NFR4: Actor audit history lookup
CREATE INDEX audit_events_actor_idx
    ON audit_events(actor_user_id, created_at DESC);

-- A9: Idempotency keys TTL pruning index
CREATE INDEX idempotency_keys_expires_idx
    ON idempotency_keys(expires_at);

-- ============================================================================
-- 3. TRIGGER FUNCTIONS AND TRIGGERS
-- ============================================================================

-- Function: set_updated_at (maintains updated_at on mutable rows)
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_driver_profiles_updated_at
    BEFORE UPDATE ON driver_profiles
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_vehicles_updated_at
    BEFORE UPDATE ON vehicles
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_trips_updated_at
    BEFORE UPDATE ON trips
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TRIGGER trg_payments_updated_at
    BEFORE UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();


-- Trigger: users_role_immutable (role cannot be changed once inserted)
CREATE OR REPLACE FUNCTION fn_users_role_immutable()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.role <> NEW.role THEN
        RAISE EXCEPTION 'users.role is immutable after insert (from % to %)', OLD.role, NEW.role
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_role_immutable
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION fn_users_role_immutable();


-- Trigger: driver_profiles_require_customer_role
CREATE OR REPLACE FUNCTION fn_driver_profiles_customer_role()
RETURNS TRIGGER AS $$
DECLARE
    v_role TEXT;
BEGIN
    SELECT role INTO v_role FROM users WHERE id = NEW.user_id;
    IF v_role <> 'customer' THEN
        RAISE EXCEPTION 'driver_profiles can only be created for users with role customer (found %)', v_role
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_driver_profiles_customer_role
    BEFORE INSERT OR UPDATE ON driver_profiles
    FOR EACH ROW EXECUTE FUNCTION fn_driver_profiles_customer_role();


-- Trigger: trips_passenger_must_be_active_customer
CREATE OR REPLACE FUNCTION fn_trips_passenger_must_be_active_customer()
RETURNS TRIGGER AS $$
DECLARE
    v_role TEXT;
    v_status TEXT;
BEGIN
    SELECT role, status INTO v_role, v_status FROM users WHERE id = NEW.passenger_id;
    IF v_role <> 'customer' OR v_status <> 'active' THEN
        RAISE EXCEPTION 'trips.passenger_id must reference an active customer user (found role=%, status=%)', v_role, v_status
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trips_passenger_check
    BEFORE INSERT ON trips
    FOR EACH ROW EXECUTE FUNCTION fn_trips_passenger_must_be_active_customer();


-- Trigger: trips_immutability (fare, currency, payment_method, requested_at, passenger_id, assignment null-to-set)
CREATE OR REPLACE FUNCTION fn_trips_immutability()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.passenger_id <> NEW.passenger_id THEN
        RAISE EXCEPTION 'trips.passenger_id is immutable after insert' USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.fare_minor <> NEW.fare_minor THEN
        RAISE EXCEPTION 'trips.fare_minor is immutable after insert' USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.currency <> NEW.currency THEN
        RAISE EXCEPTION 'trips.currency is immutable after insert' USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.payment_method <> NEW.payment_method THEN
        RAISE EXCEPTION 'trips.payment_method is immutable after insert' USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.requested_at <> NEW.requested_at THEN
        RAISE EXCEPTION 'trips.requested_at is immutable after insert' USING ERRCODE = 'check_violation';
    END IF;

    -- Assignment immutability (BR16): driver and vehicle can move from NULL to non-NULL only once
    IF OLD.driver_id IS NOT NULL AND (OLD.driver_id <> NEW.driver_id OR NEW.driver_id IS NULL) THEN
        RAISE EXCEPTION 'trips.driver_id cannot be reassigned once set' USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.vehicle_id IS NOT NULL AND (OLD.vehicle_id <> NEW.vehicle_id OR NEW.vehicle_id IS NULL) THEN
        RAISE EXCEPTION 'trips.vehicle_id cannot be reassigned once set' USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trips_immutability
    BEFORE UPDATE ON trips
    FOR EACH ROW EXECUTE FUNCTION fn_trips_immutability();


-- Trigger: trips_state_machine (enforces transition allowlist and terminal-state immutability)
CREATE OR REPLACE FUNCTION fn_trips_state_machine()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;

    -- Terminal states: completed, cancelled, expired cannot transition to any other status
    IF OLD.status IN ('completed', 'cancelled', 'expired') THEN
        RAISE EXCEPTION 'Illegal state transition: trip in terminal status % cannot be modified to %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;

    -- Transition allowlist according to docs/state-machines.md
    IF OLD.status = 'requested' AND NEW.status IN ('accepted', 'cancelled', 'expired') THEN
        RETURN NEW;
    ELSIF OLD.status = 'accepted' AND NEW.status IN ('driver_arriving', 'cancelled') THEN
        RETURN NEW;
    ELSIF OLD.status = 'driver_arriving' AND NEW.status IN ('in_progress', 'cancelled') THEN
        RETURN NEW;
    ELSIF OLD.status = 'in_progress' AND NEW.status = 'completed' THEN
        RETURN NEW;
    ELSE
        RAISE EXCEPTION 'Illegal state transition: cannot transition trip from % to %', OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trips_state_machine
    BEFORE UPDATE OF status ON trips
    FOR EACH ROW EXECUTE FUNCTION fn_trips_state_machine();


-- Trigger: reviews_eligibility (requires trip status = 'completed' and assigned driver)
CREATE OR REPLACE FUNCTION fn_reviews_eligibility()
RETURNS TRIGGER AS $$
DECLARE
    v_status TEXT;
    v_driver_id UUID;
BEGIN
    SELECT status, driver_id INTO v_status, v_driver_id FROM trips WHERE id = NEW.trip_id;
    IF v_status <> 'completed' THEN
        RAISE EXCEPTION 'Reviews can only be created for completed trips (current status is %)', v_status
            USING ERRCODE = 'check_violation';
    END IF;
    IF v_driver_id IS NULL THEN
        RAISE EXCEPTION 'Reviews can only be created for trips with an assigned driver'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reviews_eligibility
    BEFORE INSERT ON reviews
    FOR EACH ROW EXECUTE FUNCTION fn_reviews_eligibility();


-- Trigger: reviews_immutability (rejects UPDATE and DELETE on reviews)
CREATE OR REPLACE FUNCTION fn_reviews_immutability()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'reviews records are immutable and cannot be updated or deleted'
        USING ERRCODE = 'check_violation';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reviews_immutability
    BEFORE UPDATE OR DELETE ON reviews
    FOR EACH ROW EXECUTE FUNCTION fn_reviews_immutability();


-- Trigger: audit_events_immutability (rejects UPDATE and DELETE on audit_events)
CREATE OR REPLACE FUNCTION fn_audit_events_immutability()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'audit_events records are append-only and cannot be updated or deleted'
        USING ERRCODE = 'check_violation';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_audit_events_immutability
    BEFORE UPDATE OR DELETE ON audit_events
    FOR EACH ROW EXECUTE FUNCTION fn_audit_events_immutability();


-- Trigger: trip_location_samples_append_only (rejects UPDATE; DELETE permitted for cascade & retention purge)
CREATE OR REPLACE FUNCTION fn_trip_location_samples_append_only()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'trip_location_samples records are append-only and cannot be updated'
        USING ERRCODE = 'check_violation';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_location_samples_append_only
    BEFORE UPDATE ON trip_location_samples
    FOR EACH ROW EXECUTE FUNCTION fn_trip_location_samples_append_only();


-- Trigger: payments_transition (pending -> succeeded, pending -> failed only; terminal states immutable)
CREATE OR REPLACE FUNCTION fn_payments_transition()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status = NEW.status THEN
        -- If settled, cannot update any other field either
        IF OLD.status IN ('succeeded', 'failed') THEN
            RAISE EXCEPTION 'Settled payments are immutable (attempt % for trip %)', OLD.attempt_no, OLD.trip_id
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
    END IF;

    IF OLD.status = 'pending' AND NEW.status IN ('succeeded', 'failed') THEN
        RETURN NEW;
    ELSE
        RAISE EXCEPTION 'Illegal payment status transition from % to % (attempt %)', OLD.status, NEW.status, OLD.attempt_no
            USING ERRCODE = 'check_violation';
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payments_transition
    BEFORE UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION fn_payments_transition();


-- Trigger: idempotency_keys_immutability (rejects UPDATE)
CREATE OR REPLACE FUNCTION fn_idempotency_keys_immutability()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'idempotency_keys records cannot be updated'
        USING ERRCODE = 'check_violation';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_idempotency_keys_immutability
    BEFORE UPDATE ON idempotency_keys
    FOR EACH ROW EXECUTE FUNCTION fn_idempotency_keys_immutability();

COMMIT;
