-- Migration 002: Trips and Location Telemetry
-- RideFlow Task 3 - PostgreSQL Migration

BEGIN;

-- Table: trips
CREATE TABLE trips (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    passenger_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    driver_id UUID NULL REFERENCES driver_profiles(user_id) ON DELETE RESTRICT,
    vehicle_id UUID NULL REFERENCES vehicles(id) ON DELETE RESTRICT,
    status TEXT NOT NULL DEFAULT 'requested' CHECK (
        status IN ('requested', 'accepted', 'driver_arriving', 'in_progress', 'completed', 'cancelled', 'expired')
    ),
    pickup_latitude NUMERIC(9,6) NOT NULL CHECK (pickup_latitude BETWEEN -90 AND 90),
    pickup_longitude NUMERIC(9,6) NOT NULL CHECK (pickup_longitude BETWEEN -180 AND 180),
    dropoff_latitude NUMERIC(9,6) NOT NULL CHECK (dropoff_latitude BETWEEN -90 AND 90),
    dropoff_longitude NUMERIC(9,6) NOT NULL CHECK (dropoff_longitude BETWEEN -180 AND 180),
    pickup_address TEXT NULL CHECK (pickup_address IS NULL OR char_length(pickup_address) <= 500),
    dropoff_address TEXT NULL CHECK (dropoff_address IS NULL OR char_length(dropoff_address) <= 500),
    fare_minor BIGINT NOT NULL CHECK (fare_minor > 0),
    currency VARCHAR(3) NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    payment_method TEXT NOT NULL CHECK (payment_method IN ('cash', 'electronic')),
    requested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    accepted_at TIMESTAMPTZ NULL,
    driver_arriving_at TIMESTAMPTZ NULL,
    started_at TIMESTAMPTZ NULL,
    completed_at TIMESTAMPTZ NULL,
    cancelled_at TIMESTAMPTZ NULL,
    cancellation_reason TEXT NULL CHECK (cancellation_reason IS NULL OR char_length(cancellation_reason) <= 500),
    expired_at TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Composite foreign key enforcing that vehicle belongs to assigned driver
    CONSTRAINT trips_driver_vehicle_fkey FOREIGN KEY (driver_id, vehicle_id)
        REFERENCES vehicles(driver_id, id) ON DELETE RESTRICT,

    -- Driver and vehicle assignment pairing: both null or both set
    CONSTRAINT trips_driver_vehicle_paired CHECK (
        (driver_id IS NULL AND vehicle_id IS NULL) OR
        (driver_id IS NOT NULL AND vehicle_id IS NOT NULL)
    ),

    -- Passenger and driver must be distinct users
    CONSTRAINT trips_passenger_differs_from_driver CHECK (
        driver_id IS NULL OR passenger_id <> driver_id
    ),

    -- Status and timestamp coherence checks
    CONSTRAINT trips_requested_state_clean CHECK (
        status <> 'requested' OR (
            driver_id IS NULL AND accepted_at IS NULL AND driver_arriving_at IS NULL
            AND started_at IS NULL AND completed_at IS NULL AND cancelled_at IS NULL AND expired_at IS NULL
        )
    ),
    CONSTRAINT trips_assigned_state_requirements CHECK (
        status NOT IN ('accepted', 'driver_arriving', 'in_progress', 'completed') OR (
            driver_id IS NOT NULL AND accepted_at IS NOT NULL
        )
    ),
    CONSTRAINT trips_driver_arriving_requirements CHECK (
        status <> 'driver_arriving' OR driver_arriving_at IS NOT NULL
    ),
    CONSTRAINT trips_in_progress_requirements CHECK (
        status NOT IN ('in_progress', 'completed') OR started_at IS NOT NULL
    ),
    CONSTRAINT trips_completed_requirements CHECK (
        status <> 'completed' OR completed_at IS NOT NULL
    ),
    CONSTRAINT trips_cancelled_requirements CHECK (
        status <> 'cancelled' OR cancelled_at IS NOT NULL
    ),
    CONSTRAINT trips_expired_requirements CHECK (
        status <> 'expired' OR (expired_at IS NOT NULL AND driver_id IS NULL AND accepted_at IS NULL)
    ),
    CONSTRAINT trips_cancellation_reason_guard CHECK (
        status = 'cancelled' OR cancellation_reason IS NULL
    ),
    CONSTRAINT trips_terminal_mutually_exclusive CHECK (
        (completed_at IS NULL OR cancelled_at IS NULL) AND
        (completed_at IS NULL OR expired_at IS NULL) AND
        (cancelled_at IS NULL OR expired_at IS NULL)
    ),
    CONSTRAINT trips_chronological_accepted CHECK (
        accepted_at IS NULL OR accepted_at >= requested_at
    ),
    CONSTRAINT trips_chronological_arriving CHECK (
        driver_arriving_at IS NULL OR driver_arriving_at >= accepted_at
    ),
    CONSTRAINT trips_chronological_started CHECK (
        started_at IS NULL OR started_at >= accepted_at
    ),
    CONSTRAINT trips_chronological_completed CHECK (
        completed_at IS NULL OR completed_at >= started_at
    ),
    CONSTRAINT trips_chronological_cancelled CHECK (
        cancelled_at IS NULL OR cancelled_at >= requested_at
    ),

    -- Unique constraints supporting child composite foreign keys
    CONSTRAINT trips_id_passenger_id_unique UNIQUE (id, passenger_id),
    CONSTRAINT trips_id_fare_currency_method_unique UNIQUE (id, fare_minor, currency, payment_method)
);

-- Table: trip_location_samples
CREATE TABLE trip_location_samples (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id UUID NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
    latitude NUMERIC(9,6) NOT NULL CHECK (latitude BETWEEN -90 AND 90),
    longitude NUMERIC(9,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
    accuracy_meters NUMERIC(7,2) NULL CHECK (accuracy_meters IS NULL OR accuracy_meters >= 0),
    recorded_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMIT;
