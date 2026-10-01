-- ==============================================================================
-- LAB IIOT PLATFORM - CENTRAL DATABASE INITIALIZATION PROFILE (PHASE 1A)
-- ==============================================================================

-- 1. Enable the TimescaleDB extension natively inside the PostgreSQL instance
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;

-- 2. Establish our dedicated operational schema space
CREATE SCHEMA IF NOT EXISTS platform_data;

-- 3. Agnostic Asset Registry Table
CREATE TABLE IF NOT EXISTS platform_data.assets (
    asset_id VARCHAR(50) PRIMARY KEY,
    asset_name VARCHAR(100) NOT NULL,
    location_zone VARCHAR(50) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 4. Agnostic Parameter/Tag Registry Table
CREATE TABLE IF NOT EXISTS platform_data.asset_tags (
    tag_id VARCHAR(100) PRIMARY KEY,
    asset_id VARCHAR(50) REFERENCES platform_data.assets(asset_id) ON DELETE CASCADE,
    tag_name VARCHAR(100) NOT NULL,
    data_type VARCHAR(20) NOT NULL CHECK (data_type IN ('float', 'boolean', 'text'))
);

-- 5. Universal High-Frequency Telemetry Data Storage Table
CREATE TABLE IF NOT EXISTS platform_data.telemetry (
    time TIMESTAMP WITH TIME ZONE NOT NULL,
    tag_id VARCHAR(100) REFERENCES platform_data.asset_tags(tag_id),
    val_float DOUBLE PRECISION,
    val_bool BOOLEAN,
    val_text TEXT
);

-- 6. Convert the telemetry table into a high-performance TimescaleDB hypertable
-- We bucket datasets into optimized 7-day partition blocks
SELECT create_hypertable('platform_data.telemetry', 'time', chunk_time_interval => INTERVAL '7 days', if_not_exists => TRUE);

-- Create spatial/temporal indexes to guarantee lightning-fast queries from Grafana
CREATE INDEX IF NOT EXISTS idx_telemetry_tag_time ON platform_data.telemetry (tag_id, time DESC);


-- ==============================================================================
-- 7. ZERO-TOUCH AUTO-DISCOVERY INGESTION PIPELINE TRIGGER
-- ==============================================================================

-- A. Establish a lightning-fast staging table matching Telegraf's output matrix
CREATE TABLE IF NOT EXISTS platform_data.telemetry_stage (
    time TIMESTAMP WITH TIME ZONE,
    asset_id TEXT,
    tag_name TEXT,
    sensor_value TEXT
);

-- B. Deploy the smart auto-discovery background data function
CREATE OR REPLACE FUNCTION platform_data.route_telemetry_stage()
RETURNS TRIGGER AS $$
DECLARE
    v_tag_id TEXT;
    v_float DOUBLE PRECISION;
    v_bool BOOLEAN;
BEGIN
    -- Construct the unified composite key string (e.g., 'biomass_pyrolyser_01.REACTOR_CORE_TEMP')
    v_tag_id := CONCAT(NEW.asset_id, '.', NEW.tag_name);

    -- 1. AUTO-REGISTER THE ASSET IF IT DOES NOT EXIST (Zero-Touch Onboarding)
    INSERT INTO platform_data.assets (asset_id, asset_name, location_zone)
    VALUES (NEW.asset_id, CONCAT('Auto-Registered: ', NEW.asset_id), 'ZONE_UNKNOWN')
    ON CONFLICT (asset_id) DO NOTHING;

    -- Evaluate string values to extract floating-point metric numbers
    BEGIN
        v_float := CAST(NEW.sensor_value AS DOUBLE PRECISION);
    EXCEPTION WHEN others THEN
        v_float := NULL;
    END;

    -- Evaluate boolean binary logic strings if float parsing results in NULL
    IF v_float IS NULL THEN
        IF LOWER(NEW.sensor_value) IN ('true', '1', 'on', 'yes') THEN
            v_bool := TRUE;
        ELSIF LOWER(NEW.sensor_value) IN ('false', '0', 'off', 'no') THEN
            v_bool := FALSE;
        ELSE
            v_bool := NULL;
        END IF;
    END IF;

    -- 2. AUTO-REGISTER THE PARAMETER TAG IF IT DOES NOT EXIST
    INSERT INTO platform_data.asset_tags (tag_id, asset_id, tag_name, data_type)
    VALUES (
        v_tag_id, 
        NEW.asset_id, 
        CONCAT(NEW.tag_name, ' (Auto)'), 
        CASE 
            WHEN v_float IS NOT NULL THEN 'float'
            WHEN v_bool IS NOT NULL THEN 'boolean'
            ELSE 'text'
        END
    )
    ON CONFLICT (tag_id) DO NOTHING;

    -- 3. Drop processed native metrics directly inside the time-series hypertable
    INSERT INTO platform_data.telemetry (time, tag_id, val_float, val_bool, val_text)
    VALUES (
        NEW.time, 
        v_tag_id, 
        v_float, 
        v_bool, 
        CASE WHEN v_float IS NULL AND v_bool IS NULL THEN NEW.sensor_value END
    );

    RETURN NULL; -- Instantly discards raw text rows from staging to ensure 0% storage bloat
END;
$$ LANGUAGE plpgsql;

-- C. Apply the execution engine trigger binding constraints cleanly
DROP TRIGGER IF EXISTS trg_route_telemetry ON platform_data.telemetry_stage;
CREATE TRIGGER trg_route_telemetry
    BEFORE INSERT ON platform_data.telemetry_stage
    FOR EACH ROW EXECUTE FUNCTION platform_data.route_telemetry_stage();
