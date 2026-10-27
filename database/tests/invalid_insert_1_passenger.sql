-- Invalid Insert Test 1: Second active trip for same passenger (BR3 / NFR1)
-- RideFlow Task 3 - Required Constraint Rejection 1
-- Prerequisite: Synthetic Passenger 1 (018d3f62-4401-7b3e-8c42-5f69a1e09100) already has one
--               active 'requested' trip inserted by the seed data.
-- Expected Failure: duplicate key value violates unique constraint "trips_active_passenger_idx" (SQLSTATE 23505)

\echo '--- TEST 1: Attempting to insert a 2nd active trip for Synthetic Passenger 1 ---'

INSERT INTO trips (
    passenger_id,
    status,
    pickup_latitude,
    pickup_longitude,
    dropoff_latitude,
    dropoff_longitude,
    fare_minor,
    currency,
    payment_method,
    requested_at
) VALUES (
    '018d3f62-4401-7b3e-8c42-5f69a1e09100',   -- Synthetic Passenger 1, already has active requested trip
    'requested',
    6.450000,
    3.400000,
    6.550000,
    3.360000,
    400000,
    'NGN',
    'cash',
    now()
);
