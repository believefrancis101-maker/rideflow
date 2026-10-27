-- Supporting Negative Test: Append-only mutations blocked (DD-3 / DD-4)
-- RideFlow Task 3 - Immutability Trigger Tests

\echo '--- TEST 6: Attempting to UPDATE an immutable review (reviews_immutability trigger) ---'

UPDATE reviews
SET rating = 1, comment = 'Attempting to maliciously modify review'
WHERE id = '018d3f62-6661-7b3e-8c42-5f69a1e09661';

\echo '--- TEST 7: Attempting to DELETE an immutable audit_event (audit_events_immutability trigger) ---'

DELETE FROM audit_events
WHERE id = (SELECT id FROM audit_events ORDER BY created_at LIMIT 1);
