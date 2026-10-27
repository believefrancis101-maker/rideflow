# RideFlow Task 3 - Stage 5B Proof Automation Script
# Executes PostgreSQL migrations, seed data, queries Q1-Q5, EXPLAIN plans, and negative constraint tests.

param (
    [string]$ContainerName = "rideflow-pg-proof",
    [int]$Port = 5433,
    [string]$User = "postgres",
    [string]$Db = "rideflow",
    [string]$Password = "postgres",
    [string]$EvidenceDir = "evidence",
    [switch]$PreserveExisting = $false
)

$ErrorActionPreference = "Continue"

Write-Host "=== RideFlow Stage 5B PostgreSQL Proof Runner ===" -ForegroundColor Cyan
Write-Host "Target Container: $ContainerName on port $Port"
Write-Host "Evidence Directory: $EvidenceDir"

# 1. Clean up prior container if not preserving or if matching target
$existing = docker ps -a --filter "name=^/${ContainerName}$" --format "{{.Names}}"
if ($existing -eq $ContainerName) {
    if ($PreserveExisting) {
        Write-Error "Container $ContainerName already exists and PreserveExisting was requested. Aborting."
        exit 1
    }
    Write-Host "Removing prior container $ContainerName..."
    docker rm -f $ContainerName | Out-Null
}

# 2. Ensure evidence directory exists
if (-not (Test-Path $EvidenceDir)) {
    New-Item -ItemType Directory -Path $EvidenceDir | Out-Null
}

# 3. Spin up fresh isolated PostgreSQL 16 Alpine container
Write-Host "Spinning up isolated container $ContainerName on port $Port..."
docker run --name $ContainerName -e POSTGRES_PASSWORD=$Password -e POSTGRES_DB=$Db -p "${Port}:5432" -d postgres:16-alpine

# Wait for PostgreSQL to be ready
Write-Host "Waiting for PostgreSQL engine to initialize..."
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $status = docker exec $ContainerName pg_isready -U $User -d $Db 2>&1
    if ($status -match "accepting connections") {
        $ready = $true
        break
    }
}

if (-not $ready) {
    Write-Error "PostgreSQL failed to become ready within 30 seconds."
    exit 1
}

Write-Host "PostgreSQL 16 is ready." -ForegroundColor Green

# 4. Apply Migrations in Forward-Only Sequence
Write-Host "`n--- Applying Migrations 001 to 004 ---" -ForegroundColor Yellow
$migrationLog = ""
$migrations = @(
    "database/migrations/001_initial_schema.sql",
    "database/migrations/002_trips_and_telemetry.sql",
    "database/migrations/003_payments_reviews_audit_idempotency.sql",
    "database/migrations/004_indexes_and_triggers.sql"
)

foreach ($mig in $migrations) {
    Write-Host "Applying $mig..."
    $content = Get-Content $mig -Raw
    $log = $content | docker exec -i $ContainerName psql -U $User -d $Db -e 2>&1
    $migrationLog += "=================================================================`n"
    $migrationLog += "APPLYING: $mig`n"
    $migrationLog += "=================================================================`n"
    $migrationLog += ($log -join "`n") + "`n`n"
}
$migrationLog | Set-Content "$EvidenceDir/01_migration_log.txt"
Write-Host "Migration log saved to $EvidenceDir/01_migration_log.txt"

# 5. Schema Inspection
Write-Host "`n--- Inspecting Schema & Constraints ---" -ForegroundColor Yellow
$inspectSql = @"
SELECT version();
\dt+
\di+
\d+ users
\d+ driver_profiles
\d+ vehicles
\d+ trips
\d+ trip_location_samples
\d+ payments
\d+ reviews
\d+ audit_events
\d+ idempotency_keys
"@
$inspectLog = $inspectSql | docker exec -i $ContainerName psql -U $User -d $Db 2>&1
($inspectLog -join "`n") | Set-Content "$EvidenceDir/02_schema_inspection.txt"
Write-Host "Schema inspection saved to $EvidenceDir/02_schema_inspection.txt"

# 6. Apply Seed Data
Write-Host "`n--- Applying Seed Data ---" -ForegroundColor Yellow
$seedContent = Get-Content "database/seeds/01_mvp_seed_data.sql" -Raw
$seedLog = $seedContent | docker exec -i $ContainerName psql -U $User -d $Db -e 2>&1
($seedLog -join "`n") | Set-Content "$EvidenceDir/03_seed_log.txt"
Write-Host "Seed log saved to $EvidenceDir/03_seed_log.txt"

# 7. Execute Action Queries Q1-Q5 in Documented Order
# Note: Q3 executes while Trip 102 is in_progress, accurately recording in-flight progress prior to Q4 completion.
Write-Host "`n--- Running Action Queries Q1-Q5 ---" -ForegroundColor Yellow
$queriesLog = ""
$queries = @(
    "database/queries/q1_request_trip.sql",
    "database/queries/q2_accept_trip.sql",
    "database/queries/q3_trip_progress.sql",
    "database/queries/q4_complete_trip.sql",
    "database/queries/q5_review_trip.sql"
)

foreach ($q in $queries) {
    Write-Host "Executing $q..."
    $qContent = Get-Content $q -Raw
    $qRes = $qContent | docker exec -i $ContainerName psql -U $User -d $Db -e 2>&1
    $queriesLog += "=================================================================`n"
    $queriesLog += "EXECUTING: $q`n"
    $queriesLog += "=================================================================`n"
    $queriesLog += ($qRes -join "`n") + "`n`n"
}
$queriesLog | Set-Content "$EvidenceDir/04_q1_to_q5_results.txt"
Write-Host "Action queries results saved to $EvidenceDir/04_q1_to_q5_results.txt"

# 8. Execute EXPLAIN (ANALYZE, BUFFERS) for Action Queries
Write-Host "`n--- Running EXPLAIN (ANALYZE, BUFFERS) for Action Queries ---" -ForegroundColor Yellow

# Query Q2 Queue Explain
$explainQ2Sql = @"
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, passenger_id, pickup_address, dropoff_address, fare_minor, currency, payment_method, created_at
FROM trips
WHERE status = 'requested'
ORDER BY created_at ASC
LIMIT 10;
"@
$explainQ2Log = $explainQ2Sql | docker exec -i $ContainerName psql -U $User -d $Db 2>&1
($explainQ2Log -join "`n") | Set-Content "$EvidenceDir/05_explain_q2_queue.txt"
Write-Host "EXPLAIN Q2 saved to $EvidenceDir/05_explain_q2_queue.txt"

# Query Q3 Trip Progress Explain
$explainQ3Sql = @"
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT t.id, t.status, t.pickup_address, t.dropoff_address, t.fare_minor, t.currency,
       u_p.full_name AS passenger_name,
       u_d.full_name AS driver_name,
       v.make, v.model, v.license_plate,
       loc.latitude AS latest_lat, loc.longitude AS latest_lon, loc.recorded_at AS latest_telemetry
FROM trips t
JOIN users u_p ON u_p.id = t.passenger_id
LEFT JOIN driver_profiles dp ON dp.user_id = t.driver_id
LEFT JOIN users u_d ON u_d.id = dp.user_id
LEFT JOIN vehicles v ON v.id = t.vehicle_id
LEFT JOIN LATERAL (
    SELECT latitude, longitude, recorded_at
    FROM trip_location_samples
    WHERE trip_id = t.id
    ORDER BY recorded_at DESC, id DESC
    LIMIT 1
) loc ON true
WHERE t.id = '018d3f62-7b1a-7b3e-8c42-5f69a1e09102';
"@
$explainQ3Log = $explainQ3Sql | docker exec -i $ContainerName psql -U $User -d $Db 2>&1
($explainQ3Log -join "`n") | Set-Content "$EvidenceDir/06_explain_q3_progress.txt"
Write-Host "EXPLAIN Q3 saved to $EvidenceDir/06_explain_q3_progress.txt"

# 9. Execute The Three Required Rejected Inserts
Write-Host "`n--- Running Three Required Rejected Inserts ---" -ForegroundColor Yellow

# Test 1: Second active trip for passenger (trips_active_passenger_idx, SQLSTATE 23505)
$t1Content = Get-Content "database/tests/invalid_insert_1_passenger.sql" -Raw
$t1Log = $t1Content | docker exec -i $ContainerName psql -U $User -d $Db -e -v VERBOSITY=verbose 2>&1
($t1Log -join "`n") | Set-Content "$EvidenceDir/07_rejected_insert_1_passenger.txt"
Write-Host "Rejected Insert 1 saved to $EvidenceDir/07_rejected_insert_1_passenger.txt"

# Test 2: Second successful payment for trip (payments_single_success_idx, SQLSTATE 23505)
$t2Content = Get-Content "database/tests/invalid_insert_2_payment.sql" -Raw
$t2Log = $t2Content | docker exec -i $ContainerName psql -U $User -d $Db -e -v VERBOSITY=verbose 2>&1
($t2Log -join "`n") | Set-Content "$EvidenceDir/08_rejected_insert_2_payment.txt"
Write-Host "Rejected Insert 2 saved to $EvidenceDir/08_rejected_insert_2_payment.txt"

# Test 3: Second review for completed trip (reviews_trip_id_key, SQLSTATE 23505)
$t3Content = Get-Content "database/tests/invalid_insert_3_review.sql" -Raw
$t3Log = $t3Content | docker exec -i $ContainerName psql -U $User -d $Db -e -v VERBOSITY=verbose 2>&1
($t3Log -join "`n") | Set-Content "$EvidenceDir/09_rejected_insert_3_review.txt"
Write-Host "Rejected Insert 3 saved to $EvidenceDir/09_rejected_insert_3_review.txt"

# 10. Execute Additional Constraint & Invariant Tests
Write-Host "`n--- Running Additional Constraint Tests ---" -ForegroundColor Yellow
$addTestsLog = ""
$addTests = @(
    "database/tests/test_cross_driver_vehicle.sql",
    "database/tests/test_forbidden_transition.sql",
    "database/tests/test_append_only_mutation.sql",
    "database/tests/test_payment_failure_non_undo.sql",
    "database/tests/test_telemetry_lifecycle.sql"
)
foreach ($t in $addTests) {
    Write-Host "Executing $t..."
    $tContent = Get-Content $t -Raw
    $tRes = $tContent | docker exec -i $ContainerName psql -U $User -d $Db -e -v VERBOSITY=verbose 2>&1
    $addTestsLog += "=================================================================`n"
    $addTestsLog += "EXECUTING: $t`n"
    $addTestsLog += "=================================================================`n"
    $addTestsLog += ($tRes -join "`n") + "`n`n"
}
$addTestsLog | Set-Content "$EvidenceDir/10_additional_tests.txt"
Write-Host "Additional tests saved to $EvidenceDir/10_additional_tests.txt"

Write-Host "`n=== Stage 5B Proof Automation Complete ===" -ForegroundColor Green
