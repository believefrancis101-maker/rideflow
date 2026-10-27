-- Supporting Negative Test: Cross-driver vehicle assignment (BR16 / DD-2)
-- RideFlow Task 3 - Composite FK Constraint Test
-- Prerequisite: Driver 1 (Chidi, 018d3f62-2221-7b3e-8c42-5f69a1e09221) exists.
--               Vehicle 2 (LAG-202BB, 018d3f62-3332-7b3e-8c42-5f69a1e09332) is owned by Driver 2.
-- Expected Failure: insert or update on table "trips" violates foreign key constraint "trips_driver_vehicle_fkey"
--                   (SQLSTATE 23503)

\echo '--- TEST 4: Attempting to assign Driver 1 with Vehicle 2 (owned by Driver 2) ---'

INSERT INTO trips (
    passenger_id,
    driver_id,
    vehicle_id,
    status,
    pickup_latitude,
    pickup_longitude,
    dropoff_latitude,
    dropoff_longitude,
    fare_minor,
    currency,
    payment_method,
    requested_at,
    accepted_at,
    driver_arriving_at,
    started_at,
    completed_at
) VALUES (
    '018d3f62-1114-7b3e-8c42-5f69a1e09114',           -- Margaret Hamilton (active customer)
    '018d3f62-2221-7b3e-8c42-5f69a1e09221',           -- Driver 1: Chidi Anagonye
    '018d3f62-3332-7b3e-8c42-5f69a1e09332',           -- Vehicle 2: LAG-202BB owned by Driver 2!
    'completed',                                       -- Terminal status avoids active-trip partial unique index
    6.450000,
    3.400000,
    6.550000,
    3.360000,
    500000,
    'NGN',
    'cash',
    now() - INTERVAL '40 minutes',
    now() - INTERVAL '35 minutes',
    now() - INTERVAL '30 minutes',
    now() - INTERVAL '25 minutes',
    now() - INTERVAL '10 minutes'
);

