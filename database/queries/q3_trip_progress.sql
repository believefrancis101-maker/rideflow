-- Action R3: Retrieve trip details and latest progress
-- RideFlow Task 3 - Query Demonstration Q3
-- Prerequisite: An active or completed trip with location telemetry samples.
-- Demonstrates: Comprehensive aggregate read joining trip, participants, vehicle, and deterministic latest location.

SELECT
    t.id AS trip_id,
    t.status AS trip_status,
    t.pickup_address,
    t.dropoff_address,
    t.fare_minor,
    t.currency,
    t.payment_method,
    t.requested_at,
    t.accepted_at,
    t.started_at,
    u_p.full_name AS passenger_name,
    u_d.full_name AS driver_name,
    v.make AS vehicle_make,
    v.model AS vehicle_model,
    v.license_plate AS vehicle_plate,
    loc.latitude AS latest_latitude,
    loc.longitude AS latest_longitude,
    loc.accuracy_meters AS latest_accuracy,
    loc.recorded_at AS latest_telemetry_time
FROM trips t
JOIN users u_p ON u_p.id = t.passenger_id
LEFT JOIN driver_profiles dp ON dp.user_id = t.driver_id
LEFT JOIN users u_d ON u_d.id = dp.user_id
LEFT JOIN vehicles v ON v.id = t.vehicle_id
LEFT JOIN LATERAL (
    SELECT latitude, longitude, accuracy_meters, recorded_at
    FROM trip_location_samples
    WHERE trip_id = t.id
    ORDER BY recorded_at DESC, id DESC
    LIMIT 1
) loc ON true
WHERE t.id = '018d3f62-7b1a-7b3e-8c42-5f69a1e09102';
