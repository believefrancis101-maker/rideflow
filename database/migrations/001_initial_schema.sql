-- Migration 001: Initial Schema (Users, Driver Profiles, Vehicles)
-- RideFlow Task 3 - PostgreSQL Migration

BEGIN;

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Table: users
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role TEXT NOT NULL DEFAULT 'customer' CHECK (role IN ('customer', 'admin')),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
    full_name TEXT NOT NULL CHECK (char_length(btrim(full_name)) > 0),
    email TEXT NOT NULL UNIQUE CHECK (email = lower(email) AND char_length(email) BETWEEN 3 AND 320),
    phone TEXT NULL CHECK (phone IS NULL OR char_length(phone) BETWEEN 7 AND 32),
    deleted_at TIMESTAMPTZ NULL CHECK (deleted_at IS NULL OR (status = 'disabled' AND deleted_at >= created_at)),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Table: driver_profiles
CREATE TABLE driver_profiles (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE RESTRICT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'suspended', 'rejected')),
    approved_at TIMESTAMPTZ NULL CHECK (status <> 'approved' OR approved_at IS NOT NULL) CHECK (approved_at IS NULL OR approved_at >= created_at),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Table: vehicles
CREATE TABLE vehicles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id UUID NOT NULL REFERENCES driver_profiles(user_id) ON DELETE RESTRICT,
    license_plate TEXT NOT NULL UNIQUE CHECK (license_plate = upper(license_plate) AND char_length(license_plate) BETWEEN 2 AND 16),
    make TEXT NOT NULL CHECK (char_length(btrim(make)) > 0),
    model TEXT NOT NULL CHECK (char_length(btrim(model)) > 0),
    color TEXT NULL CHECK (color IS NULL OR char_length(color) <= 40),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'suspended')),
    approved_at TIMESTAMPTZ NULL CHECK (status <> 'approved' OR approved_at IS NOT NULL) CHECK (approved_at IS NULL OR approved_at >= created_at),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT vehicles_driver_id_id_unique UNIQUE (driver_id, id)
);

COMMIT;
