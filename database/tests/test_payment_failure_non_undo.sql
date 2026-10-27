-- Supporting Invariant Test: Electronic payment failure does NOT undo trip completion (BR14)
-- RideFlow Task 3 - Payment Lifecycle Integrity Test
-- Prerequisite: Trip 102 (018d3f62-7b1a-7b3e-8c42-5f69a1e09102) is 'completed' with successful payment attempt #1.
-- Demonstrates: Inserting a second failed payment attempt records the failure details but leaves the trip in 'completed' status.

\echo '--- TEST 8: Electronic payment failure does NOT undo trip completion (BR14) ---'

BEGIN;

INSERT INTO payments (
    trip_id,
    attempt_no,
    method,
    amount_minor,
    currency,
    status,
    failure_code,
    settled_at
) VALUES (
    '018d3f62-7b1a-7b3e-8c42-5f69a1e09102',
    2,
    'electronic',
    650000,
    'NGN',
    'failed',
    'PROVIDER_TIMEOUT',
    now()
) RETURNING id, trip_id, attempt_no, status, failure_code, settled_at;

SELECT id, status, completed_at
FROM trips
WHERE id = '018d3f62-7b1a-7b3e-8c42-5f69a1e09102';

ROLLBACK;
