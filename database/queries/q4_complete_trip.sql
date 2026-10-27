-- Action R4: Complete trip and record payment outcome
-- RideFlow Task 3 - Query Demonstration Q4
-- Prerequisite: Trip in 'in_progress' status.
-- Demonstrates: Atomic transition to 'completed', terminal state setting, and payment attempt recording matching agreed fare snapshot.

BEGIN;

-- Step 1: Transition trip from 'in_progress' to 'completed'
UPDATE trips
SET status = 'completed',
    completed_at = now()
WHERE id = '018d3f62-7b1a-7b3e-8c42-5f69a1e09102'
  AND status = 'in_progress'
RETURNING id, status, fare_minor, currency, payment_method, completed_at;

-- Step 2: Record successful payment outcome matching the exact trip fare snapshot
INSERT INTO payments (
    id,
    trip_id,
    attempt_no,
    method,
    amount_minor,
    currency,
    status,
    provider_reference,
    settled_at
) VALUES (
    '018d3f62-5552-7b3e-8c42-5f69a1e09552',
    '018d3f62-7b1a-7b3e-8c42-5f69a1e09102',
    1,
    'electronic',
    650000,
    'NGN',
    'succeeded',
    'ext_pay_ref_998877',
    now()
) RETURNING id, trip_id, attempt_no, method, amount_minor, currency, status, provider_reference, settled_at;

-- Step 3: Record completion and payment audit records
INSERT INTO audit_events (
    actor_type,
    actor_user_id,
    action,
    entity_type,
    entity_id,
    after_data
) VALUES (
    'customer',
    '018d3f62-2222-7b3e-8c42-5f69a1e09222',
    'trip.complete',
    'trips',
    '018d3f62-7b1a-7b3e-8c42-5f69a1e09102',
    jsonb_build_object('status', 'completed', 'payment_status', 'succeeded')
);

COMMIT;
