-- Supporting Negative Test: Forbidden State Transition (BR12 / DD-1)
-- RideFlow Task 3 - State Machine Trigger Test
-- Prerequisite: Trip 1 (018d3f62-7b1a-7b3e-8c42-5f69a1e09101) is in terminal state 'completed'.
-- Expected Failure: Illegal state transition: trip in terminal status completed cannot be modified to in_progress
--                   SQLSTATE 23514 (check_violation)

\echo '--- TEST 5: Attempting forbidden state transition from completed back to in_progress ---'

UPDATE trips
SET status = 'in_progress'
WHERE id = '018d3f62-7b1a-7b3e-8c42-5f69a1e09101';
