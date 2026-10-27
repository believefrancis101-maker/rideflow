-- Supporting Invariant Tests: Telemetry Append-Only & Cascade Retention Policy (DD-4)
-- RideFlow Task 3 - Telemetry Lifecycle Tests

\echo '--- TEST 9: Telemetry append-only - UPDATE blocked (DD-4) ---'

UPDATE trip_location_samples
SET latitude = 0.0
WHERE id = (SELECT id FROM trip_location_samples WHERE trip_id = '018d3f62-7b1a-7b3e-8c42-5f69a1e09101' LIMIT 1);

\echo '--- TEST 10: Telemetry cascade delete verified (approved retention policy) ---'

SELECT constraint_name, delete_rule
FROM information_schema.referential_constraints
WHERE constraint_name = 'trip_location_samples_trip_id_fkey';
