-- Action R5: Passenger reviews completed trip
-- RideFlow Task 3 - Query Demonstration Q5
-- Prerequisite: Completed trip with assigned driver, review created by the trip's passenger.
-- Demonstrates: Single immutable review insertion backed by composite ownership FK and completed trip check.

BEGIN;

-- Insert review for completed Trip 2 (completed in Q4) by Passenger Grace Hopper
INSERT INTO reviews (
    id,
    trip_id,
    passenger_id,
    rating,
    comment
) VALUES (
    '018d3f62-6662-7b3e-8c42-5f69a1e09662',
    '018d3f62-7b1a-7b3e-8c42-5f69a1e09102',
    '018d3f62-1112-7b3e-8c42-5f69a1e09112',
    5,
    'Tahani was an exceptional driver! Seamless trip and very clean vehicle.'
) RETURNING id, trip_id, passenger_id, rating, comment, created_at;

-- Audit review creation
INSERT INTO audit_events (
    actor_type,
    actor_user_id,
    action,
    entity_type,
    entity_id,
    after_data
) VALUES (
    'customer',
    '018d3f62-1112-7b3e-8c42-5f69a1e09112',
    'trip.review',
    'reviews',
    '018d3f62-6662-7b3e-8c42-5f69a1e09662',
    jsonb_build_object('rating', 5)
);

COMMIT;
