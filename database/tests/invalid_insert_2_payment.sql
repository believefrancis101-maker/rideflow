-- Invalid Insert Test 2: Second successful payment for the same trip (BR9 / NFR5)
-- RideFlow Task 3 - Required Constraint Rejection 2
-- Prerequisite: Trip 1 (018d3f62-7b1a-7b3e-8c42-5f69a1e09101) is 'completed' with
--               payment attempt #1 already in status='succeeded' (seeded).
-- Expected Failure: duplicate key value violates unique constraint "payments_single_success_idx" (SQLSTATE 23505)

\echo '--- TEST 2: Attempting to insert a 2nd successful payment for Trip 1 ---'

INSERT INTO payments (
    trip_id,
    attempt_no,
    method,
    amount_minor,
    currency,
    status,
    settled_at
) VALUES (
    '018d3f62-7b1a-7b3e-8c42-5f69a1e09101',   -- Trip 1: completed, already has succeeded payment #1
    2,
    'cash',
    450000,
    'NGN',
    'succeeded',
    now()
);
