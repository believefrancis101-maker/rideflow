-- Action R2: Retrieve queue and conditionally accept trip
-- RideFlow Task 3 - Query Demonstration Q2
-- Prerequisite: Trip in 'requested' status and eligible approved driver with approved vehicle.
-- Demonstrates: FIFO queue retrieval and safe conditional assignment under concurrency.

-- Step 1: Read the unassigned requested queue in FIFO order (backed by trips_requested_queue_idx)
SELECT
    id,
    passenger_id,
    pickup_address,
    dropoff_address,
    fare_minor,
    currency,
    payment_method,
    created_at AS queue_arrival_time
FROM trips
WHERE status = 'requested'
ORDER BY created_at ASC
LIMIT 10;

-- Step 2: Atomic conditional acceptance by an approved driver (Driver 1 with Vehicle 1)
-- Only updates if the trip is currently 'requested', preventing double-assignment races
BEGIN;

UPDATE trips
SET status = 'accepted',
    driver_id = '018d3f62-2221-7b3e-8c42-5f69a1e09221',
    vehicle_id = '018d3f62-3331-7b3e-8c42-5f69a1e09331',
    accepted_at = now()
WHERE id = '018d3f62-7b1a-7b3e-8c42-5f69a1e09103'
  AND status = 'requested'
RETURNING id, passenger_id, driver_id, vehicle_id, status, accepted_at;

-- Step 3: Record audit event for acceptance
INSERT INTO audit_events (
    actor_type,
    actor_user_id,
    action,
    entity_type,
    entity_id,
    after_data
) VALUES (
    'customer',
    '018d3f62-2221-7b3e-8c42-5f69a1e09221',
    'trip.accept',
    'trips',
    '018d3f62-7b1a-7b3e-8c42-5f69a1e09103',
    jsonb_build_object(
        'status', 'accepted',
        'driver_id', '018d3f62-2221-7b3e-8c42-5f69a1e09221',
        'vehicle_id', '018d3f62-3331-7b3e-8c42-5f69a1e09331'
    )
);

COMMIT;
