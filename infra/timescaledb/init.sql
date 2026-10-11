-- ==============================================================================
-- LAB IIOT PLATFORM - CENTRAL DATABASE INITIALIZATION PROFILE (PHASE 1B)
-- Agnostic multi-PLC ingest with optional type hints
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
SELECT create_hypertable('platform_data.telemetry', 'time',
                         chunk_time_interval => INTERVAL '7 days',
                         if_not_exists => TRUE);

-- Composite index for fast per-tag time-range queries from Grafana
CREATE INDEX IF NOT EXISTS idx_telemetry_tag_time
    ON platform_data.telemetry (tag_id, time DESC);


-- ==============================================================================
-- 7. TAG TYPE HINTS  (optional, agnostic-friendly)
--
-- A declarative table that lets operators pre-declare the expected data_type
-- of any (asset_id, tag_name) pair. When populated, the trigger uses these
-- hints instead of inferring from the first observed value.
--
-- Leave empty to fall back to automatic inference (Phase 1A behavior).
-- Populate from PLC tag sheets to guarantee stable types across restarts,
-- value-format changes, or ambiguous boolean-as-number encodings.
-- ==============================================================================

CREATE TABLE IF NOT EXISTS platform_data.tag_type_hints (
    asset_id  VARCHAR(50)  NOT NULL,
    tag_name  VARCHAR(100) NOT NULL,
    data_type VARCHAR(20)  NOT NULL CHECK (data_type IN ('float', 'boolean', 'text')),
    notes     TEXT,
    PRIMARY KEY (asset_id, tag_name)
);

COMMENT ON TABLE platform_data.tag_type_hints IS
    'Optional type overrides per (asset_id, tag_name). Empty table = pure inference.';


-- ==============================================================================
-- 8. ZERO-TOUCH AUTO-DISCOVERY INGESTION PIPELINE TRIGGER (RAW JSON UNPIVOT)
-- ==============================================================================

-- A. Staging table that receives one row per MQTT message
CREATE TABLE IF NOT EXISTS platform_data.mqtt_consumer (
    time     TIMESTAMP WITH TIME ZONE,
    topic    TEXT,
    asset_id TEXT,
    fields   JSONB               -- Holds the raw horizontal data payload object
);

-- B. Unpivot function with hint-aware type resolution
CREATE OR REPLACE FUNCTION platform_data.route_telemetry_stage()
RETURNS TRIGGER AS $$
DECLARE
    r            RECORD;
    v_asset_id   TEXT;
    v_tag_id     TEXT;
    v_hint_type  TEXT;
    v_float      DOUBLE PRECISION;
    v_bool       BOOLEAN;
    v_text       TEXT;
BEGIN
    -- Extract asset_id from MQTT topic path (lab/<asset_id>/telemetry)
    v_asset_id := split_part(NEW.topic, '/', 2);

    -- Fallback to explicit column if topic format is non-standard
    IF v_asset_id IS NULL OR v_asset_id = '' THEN
        v_asset_id := NEW.asset_id;
    END IF;

    -- Guard: nothing to route
    IF NEW.fields IS NULL OR NEW.fields = '{}'::jsonb THEN
        RETURN NULL;
    END IF;

    -- Guard: unrecognized topic shape
    IF v_asset_id IS NULL OR v_asset_id = '' OR v_asset_id = 'telemetry' THEN
        RAISE WARNING 'route_telemetry_stage: unrecognized topic format: %', NEW.topic;
        RETURN NULL;
    END IF;

    -- 1. Auto-register the asset (zero-touch onboarding)
    INSERT INTO platform_data.assets (asset_id, asset_name, location_zone)
    VALUES (v_asset_id, CONCAT('Auto-Registered: ', v_asset_id), 'ZONE_UNKNOWN')
    ON CONFLICT (asset_id) DO NOTHING;

    -- 2. Iterate over every field in the JSON payload
    FOR r IN SELECT * FROM jsonb_each_text(NEW.fields) LOOP

        -- Skip tracking metadata injected by upstream processors
        IF r.key IN ('asset_id', 'topic') THEN
            CONTINUE;
        END IF;

        v_tag_id := CONCAT(v_asset_id, '.', r.key);

        -- Reset per-iteration values
        v_float := NULL;
        v_bool  := NULL;
        v_text  := NULL;

        -- 3. Look up an optional type hint
        SELECT data_type INTO v_hint_type
        FROM platform_data.tag_type_hints
        WHERE asset_id = v_asset_id AND tag_name = r.key;

        -- 4. Resolve value based on hint, or fall back to inference
        IF v_hint_type = 'float' THEN
            BEGIN
                v_float := CAST(r.value AS DOUBLE PRECISION);
            EXCEPTION WHEN others THEN
                v_float := NULL;
            END;
            -- If hint says float but value won't parse, store as text so
            -- nothing is silently lost. The tag registry remains 'float'.
            IF v_float IS NULL THEN
                v_text := r.value;
            END IF;

        ELSIF v_hint_type = 'boolean' THEN
            IF LOWER(r.value) IN ('true', '1', 'on', 'yes') THEN
                v_bool := TRUE;
            ELSIF LOWER(r.value) IN ('false', '0', 'off', 'no') THEN
                v_bool := FALSE;
            ELSE
                -- Hint says boolean but value isn't recognized
                v_text := r.value;
            END IF;

        ELSIF v_hint_type = 'text' THEN
            v_text := r.value;

        ELSE
            -- No hint: infer from the value itself (Phase 1A behavior)
            BEGIN
                v_float := CAST(r.value AS DOUBLE PRECISION);
            EXCEPTION WHEN others THEN
                v_float := NULL;
            END;

            IF v_float IS NULL THEN
                IF LOWER(r.value) IN ('true', '1', 'on', 'yes') THEN
                    v_bool := TRUE;
                ELSIF LOWER(r.value) IN ('false', '0', 'off', 'no') THEN
                    v_bool := FALSE;
                ELSE
                    v_text := r.value;
                END IF;
            END IF;
        END IF;

        -- 5. Auto-register the tag with the resolved type
        INSERT INTO platform_data.asset_tags (tag_id, asset_id, tag_name, data_type)
        VALUES (
            v_tag_id,
            v_asset_id,
            CONCAT(r.key, ' (Auto)'),
            CASE
                WHEN v_hint_type IN ('float', 'boolean', 'text') THEN v_hint_type
                WHEN v_float IS NOT NULL THEN 'float'
                WHEN v_bool  IS NOT NULL THEN 'boolean'
                ELSE 'text'
            END
        )
        ON CONFLICT (tag_id) DO NOTHING;

        -- 6. Insert the typed measurement into the hypertable
        INSERT INTO platform_data.telemetry (time, tag_id, val_float, val_bool, val_text)
        VALUES (NEW.time, v_tag_id, v_float, v_bool, v_text);

    END LOOP;

    RETURN NULL;  -- Discard the staging row (0% disk bloat)
END;
$$ LANGUAGE plpgsql;

-- C. Bind the trigger to the staging table
DROP TRIGGER IF EXISTS trg_route_telemetry ON platform_data.mqtt_consumer;
CREATE TRIGGER trg_route_telemetry
    BEFORE INSERT ON platform_data.mqtt_consumer
    FOR EACH ROW EXECUTE FUNCTION platform_data.route_telemetry_stage();


-- ==============================================================================
-- 9. OPTIONAL SEED HINTS
-- Populate tag_type_hints from your PLC tag sheets. The trigger will use these
-- to bypass inference and enforce stable typing across all PLCs.
--
-- Example (commented out -- uncomment and adapt as needed):
--
-- INSERT INTO platform_data.tag_type_hints (asset_id, tag_name, data_type) VALUES
--     ('biomass_pyrolyser_01', 'biomass_hopper_airlock_valve_motor_current', 'float'),
--     ('biomass_pyrolyser_01', 'pyrolyzer_heater_power',                     'float'),
--     ('biomass_pyrolyser_01', 'on_off_valve_for_condensor_entry',           'boolean')
-- ON CONFLICT (asset_id, tag_name) DO NOTHING;
-- ==============================================================================
