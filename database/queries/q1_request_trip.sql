-- Action R1: Passenger requests a trip
-- RideFlow Task 3 - Query Demonstration Q1
-- Prerequisite: Active customer passenger with no existing active trip.
-- Demonstrates: Atomic creation of trip in 'requested' status with fare snapshot and currency.

BEGIN;

-- 1. Create the trip request
INSERT INTO trips (
    id,
    passenger_id,
    status,
    pickup_latitude,
    pickup_longitude,
    dropoff_latitude,
    dropoff_longitude,
    pickup_address,
    dropoff_address,
    fare_minor,
    currency,
    payment_method,
    requested_at
) VALUES (
    '018d3f62-7b1a-7b3e-8c42-5f69a1e09199',
    '018d3f62-1111-7b3e-8c42-5f69a1e09111',
    'requested',
    6.524379,
    3.379206,
    6.601838,
    3.351486,
    'Commercial Avenue, Yaba, Lagos',
    'Ikeja City Mall, Alausa, Ikeja',
    550000,
    'NGN',
    'cash',
    now()
) RETURNING id, passenger_id, status, fare_minor, currency, payment_method, requested_at;

-- 2. Audit record for trip creation
INSERT INTO audit_events (
    actor_type,
    actor_user_id,
    action,
    entity_type,
    entity_id,
    after_data
) VALUES (
    'customer',
    '018d3f62-1111-7b3e-8c42-5f69a1e09111',
    'trip.request',
    'trips',
    '018d3f62-7b1a-7b3e-8c42-5f69a1e09199',
    jsonb_build_object('status', 'requested', 'fare_minor', 550000, 'currency', 'NGN', 'payment_method', 'cash')
);

COMMIT;
