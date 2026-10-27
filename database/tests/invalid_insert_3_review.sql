-- Invalid Insert Test 3: Second review for the same completed trip (BR10 / NFR1)
-- RideFlow Task 3 - Required Constraint Rejection 3
-- Prerequisite: Trip 1 (018d3f62-7b1a-7b3e-8c42-5f69a1e09101) already has one review (seeded).
-- Expected Failure: duplicate key value violates unique constraint "reviews_trip_id_key" (SQLSTATE 23505)

\echo '--- TEST 3: Attempting to insert a 2nd review for Trip 1 ---'

INSERT INTO reviews (
    trip_id,
    passenger_id,
    rating,
    comment
) VALUES (
    '018d3f62-7b1a-7b3e-8c42-5f69a1e09101',   -- Trip 1: already has a review
    '018d3f62-1111-7b3e-8c42-5f69a1e09111',   -- Ada Lovelace, the original passenger
    4,
    'Attempting a second review on the same trip.'
);
