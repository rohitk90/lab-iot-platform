-- ==============================================================================
-- LAB IIOT PLATFORM - CENTRAL DATABASE INITIALIZATION PROFILE (PHASE 1A FINAL)
-- ==============================================================================

-- 1. Enable the TimescaleDB extension natively inside the PostgreSQL cluster
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;

-- 2. Establish our dedicated operational industrial schema space
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

-- 5. Universal High-Frequency Telemetry Data Storage Table (Hypertable Target)
CREATE TABLE IF NOT EXISTS platform_data.telemetry (
    time TIMESTAMP WITH TIME ZONE NOT NULL,
    tag_id VARCHAR(100) REFERENCES platform_data.asset_tags(tag_id),
    val_float DOUBLE PRECISION,
    val_bool BOOLEAN,
    val_text TEXT
);

-- 6. Convert the telemetry table into a high-performance TimescaleDB hypertable
-- We bucket high-frequency datasets into optimized 7-day partition blocks
SELECT create_hypertable('platform_data.telemetry', 'time', chunk_time_interval => INTERVAL '7 days', if_not_exists => TRUE);

-- Create spatial/temporal composite indexes to guarantee lightning-fast queries from Grafana
CREATE INDEX IF NOT EXISTS idx_telemetry_tag_time ON platform_data.telemetry (tag_id, time DESC);


-- ==============================================================================
-- 7. ZERO-TOUCH AUTO-DISCOVERY INGESTION PIPELINE TRIGGER (RAW JSON UNPIVOT)
-- ==============================================================================

-- A. Establish a lightning-fast staging table matching Telegraf json_v2 output fields
CREATE TABLE IF NOT EXISTS platform_data.mqtt_consumer (
    time TIMESTAMP WITH TIME ZONE,
    topic TEXT,
    asset_id TEXT,
    fields JSONB               -- Holds the raw horizontal data payload object securely
);

-- B. Deploy the smart auto-discovery background data unpivot function
CREATE OR REPLACE FUNCTION platform_data.route_telemetry_stage()
RETURNS TRIGGER AS $$
DECLARE
    r RECORD;
    v_asset_id TEXT;
    v_tag_id TEXT;
    v_float DOUBLE PRECISION;
    v_bool BOOLEAN;
BEGIN
    -- Extract the true asset_id directly from the MQTT topic path token string (lab/<asset_id>/telemetry)
    v_asset_id := split_part(NEW.topic, '/', 2);

    -- If topic format is non-standard, fallback to metadata tag parameter strings
    IF v_asset_id IS NULL OR v_asset_id = '' THEN
        v_asset_id := NEW.asset_id;
    END IF;

    -- 1. AUTO-REGISTER THE ASSET IF IT DOES NOT EXIST (Zero-Touch Onboarding)
    INSERT INTO platform_data.assets (asset_id, asset_name, location_zone)
    VALUES (v_asset_id, CONCAT('Auto-Registered: ', v_asset_id), 'ZONE_UNKNOWN')
    ON CONFLICT (asset_id) DO NOTHING;

    -- 2. DYNAMICALLY LOOP THROUGH ALL UNPIVOTED KEYS IN THE JSONB FIELDS PAYLOAD
    FOR r IN SELECT * FROM jsonb_each_text(NEW.fields) LOOP
        
        -- Ignore tracking metadata variables injected by Telegraf
        IF r.key IN ('asset_id', 'topic') THEN
            CONTINUE;
        END IF;

        v_tag_id := CONCAT(v_asset_id, '.', r.key);

        -- Evaluate text data strings to extract floating-point metrics safely
        BEGIN
            v_float := CAST(r.value AS DOUBLE PRECISION);
        EXCEPTION WHEN others THEN
            v_float := NULL;
        END;

        -- Evaluate boolean binary logic strings if float parsing results in NULL values
        IF v_float IS NULL THEN
            IF LOWER(r.value) IN ('true', '1', 'on', 'yes') THEN
                v_bool := TRUE;
            ELSIF LOWER(r.value) IN ('false', '0', 'off', 'no') THEN
                v_bool := FALSE;
            ELSE
                v_bool := NULL;
            END IF;
        END IF;

        -- 3. AUTO-REGISTER THE PARAMETER TAG IF IT DOES NOT EXIST NATIVELY IN METADATA
        INSERT INTO platform_data.asset_tags (tag_id, asset_id, tag_name, data_type)
        VALUES (
            v_tag_id, 
            v_asset_id, 
            CONCAT(r.key, ' (Auto)'), 
            CASE 
                WHEN v_float IS NOT NULL THEN 'float'
                WHEN v_bool IS NOT NULL THEN 'boolean'
                ELSE 'text'
            END
        )
        ON CONFLICT (tag_id) DO NOTHING;

        -- 4. Route processed native typed metrics directly inside our time-series hypertable columns
        INSERT INTO platform_data.telemetry (time, tag_id, val_float, val_bool, val_text)
        VALUES (
            NEW.time, 
            v_tag_id, 
            v_float, 
            v_bool, 
            CASE WHEN v_float IS NULL AND v_bool IS NULL THEN r.value END
        );
    END LOOP;

    RETURN NULL; -- Instantly discards raw JSON from staging to ensure 0% host storage disk bloat
END;
$$ LANGUAGE plpgsql;

-- C. Apply the execution engine trigger binding constraints cleanly to the active staging pad
DROP TRIGGER IF EXISTS trg_route_telemetry ON platform_data.mqtt_consumer;
CREATE TRIGGER trg_route_telemetry
    BEFORE INSERT ON platform_data.mqtt_consumer
    FOR EACH ROW EXECUTE FUNCTION platform_data.route_telemetry_stage();
