-- =============================================================================
-- LAB IIOT PLATFORM - CENTRAL DATABASE INITIALIZATION
-- Version: V2.3 (production candidate)
-- Target: PostgreSQL 16+ and TimescaleDB 2.x
-- Status: validate against the exact deployed TimescaleDB build before rollout
--
-- IMPORTANT:
--   1. Initialization script for a NEW platform_data schema. It is NOT an
--      in-place migration from V1/V2/V2.1/V2.2; those need a reviewed migration.
--   2. MinIO export is done by an external archival worker. SQL cannot write to
--      MinIO. The database only gates deletion (see drop_verified_archived_chunks).
--   3. No automatic add_retention_policy() is installed, by design.
--   4. Test with the exact Telegraf JSON/SQL mapping before production rollout.
--
-- Changes versus V2.2:
--   * First-seen tags whose type cannot be determined (NULL, NaN, +/-Infinity,
--     with no hint) are NOT registered. V2.2 registered them as 'text', which
--     permanently misrouted every later numeric sample into val_text.
--   * Float parsing uses pg_input_is_valid() (PG16), so no subtransaction is
--     opened per sample. NaN/Infinity never enter val_float; they go to val_text.
--   * Tag lookup is by the natural key (asset_id, tag_name), one indexed lookup
--     per sample. Type hints are consulted only at first sight of a tag.
--   * asset_id may not contain '.', so tag_id = asset_id || '.' || tag_name can
--     never collide across different (asset, tag) pairs.
--   * tag_type_hints no longer has an FK to assets, so hints can be declared
--     BEFORE the first message from a new asset arrives (the FK made that fail).
--   * Redundant BRIN index on time removed (chunk exclusion + the composite
--     index already cover time-range access).
--   * updated_at columns are now maintained by a trigger.
--   * Constraint renamed to telemetry_at_most_one_value (it allows all-NULL).
--   * Manifest: unique (bucket, key), dropped_at audit column.
--   * Archive view matches the manifest on chunk time range, not just name.
--   * drop_verified_archived_chunks(): database-enforced drop gate that requires
--     a verified manifest row AND a matching row count before dropping a chunk.
--   * tag_type_hint_mismatches view to spot hints that disagree with the registry.
-- =============================================================================

-- Outside the transaction: idempotent, and keeps extension loading simple.
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;

BEGIN;

CREATE SCHEMA IF NOT EXISTS platform_data;

-- ---------------------------------------------------------------------------
-- 0. Preconditions
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF current_setting('server_version_num')::int < 160000 THEN
        RAISE EXCEPTION
          'V2.3 requires PostgreSQL 16+ (pg_input_is_valid). Detected: %',
          current_setting('server_version');
    END IF;

    IF to_regclass('platform_data.asset_tags') IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM information_schema.columns
           WHERE table_schema = 'platform_data'
             AND table_name = 'asset_tags'
             AND column_name = 'tag_serial')
    THEN
        RAISE EXCEPTION
          'Incompatible platform_data.asset_tags (no tag_serial). Fresh V2.3 '
          'only; perform a tested migration instead of rerunning initialization.';
    END IF;

    IF to_regclass('platform_data.telemetry') IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM information_schema.columns
           WHERE table_schema = 'platform_data'
             AND table_name = 'telemetry'
             AND column_name = 'tag_serial')
    THEN
        RAISE EXCEPTION
          'Incompatible platform_data.telemetry (no tag_serial). Perform a '
          'tested migration before applying V2.3.';
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. Shared helper: maintain updated_at
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform_data.touch_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Asset and tag registries
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS platform_data.assets (
    asset_id       VARCHAR(100) PRIMARY KEY,
    asset_name     VARCHAR(150) NOT NULL,
    location_zone  VARCHAR(100) NOT NULL DEFAULT 'ZONE_UNKNOWN',
    description    TEXT,
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT assets_id_no_dot CHECK (position('.' IN asset_id) = 0),
    CONSTRAINT assets_id_not_blank CHECK (btrim(asset_id) <> '')
);

COMMENT ON CONSTRAINT assets_id_no_dot ON platform_data.assets IS
    'tag_id = asset_id || ''.'' || tag_name must be unambiguous, so asset_id '
    'may not contain a dot (tag_name may).';

CREATE TABLE IF NOT EXISTS platform_data.asset_tags (
    tag_serial  BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    tag_id      VARCHAR(255) NOT NULL UNIQUE,
    asset_id    VARCHAR(100) NOT NULL
                REFERENCES platform_data.assets(asset_id) ON DELETE RESTRICT,
    tag_name    VARCHAR(150) NOT NULL,
    data_type   VARCHAR(20) NOT NULL
                CHECK (data_type IN ('float', 'boolean', 'text')),
    unit        VARCHAR(50),
    description TEXT,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (asset_id, tag_name)
);

CREATE INDEX IF NOT EXISTS idx_asset_tags_asset
    ON platform_data.asset_tags (asset_id);

-- Optional type declarations, consulted ONLY when a tag is first discovered.
-- Deliberately no FK to assets: hints may be declared before the asset has
-- sent its first message. Changing a hint never alters an already registered
-- tag; see the tag_type_hint_mismatches view.
CREATE TABLE IF NOT EXISTS platform_data.tag_type_hints (
    asset_id   VARCHAR(100) NOT NULL,
    tag_name   VARCHAR(150) NOT NULL,
    data_type  VARCHAR(20) NOT NULL
               CHECK (data_type IN ('float', 'boolean', 'text')),
    notes      TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (asset_id, tag_name)
);

COMMENT ON TABLE platform_data.tag_type_hints IS
    'Optional type hints used when a tag is first auto-registered. Existing '
    'tag types remain stable; changing them requires an explicit migration.';

DROP TRIGGER IF EXISTS trg_assets_touch ON platform_data.assets;
CREATE TRIGGER trg_assets_touch
    BEFORE UPDATE ON platform_data.assets
    FOR EACH ROW EXECUTE FUNCTION platform_data.touch_updated_at();

DROP TRIGGER IF EXISTS trg_asset_tags_touch ON platform_data.asset_tags;
CREATE TRIGGER trg_asset_tags_touch
    BEFORE UPDATE ON platform_data.asset_tags
    FOR EACH ROW EXECUTE FUNCTION platform_data.touch_updated_at();

DROP TRIGGER IF EXISTS trg_tag_type_hints_touch ON platform_data.tag_type_hints;
CREATE TRIGGER trg_tag_type_hints_touch
    BEFORE UPDATE ON platform_data.tag_type_hints
    FOR EACH ROW EXECUTE FUNCTION platform_data.touch_updated_at();

-- ---------------------------------------------------------------------------
-- 3. Typed telemetry hypertable
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS platform_data.telemetry (
    time             TIMESTAMPTZ NOT NULL,
    tag_serial       BIGINT NOT NULL
                     REFERENCES platform_data.asset_tags(tag_serial)
                     ON DELETE RESTRICT,
    val_float        DOUBLE PRECISION,
    val_bool         BOOLEAN,
    val_text         TEXT,
    source_host      TEXT,
    source_timestamp TIMESTAMPTZ,
    ingested_at      TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    sequence_number  BIGINT,
    quality_code     TEXT NOT NULL DEFAULT 'UNKNOWN'
        CHECK (quality_code IN ('GOOD', 'BAD', 'UNCERTAIN', 'UNKNOWN')),
    -- All three NULL is allowed on purpose: it records a null observation.
    CONSTRAINT telemetry_at_most_one_value CHECK (
        (CASE WHEN val_float IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN val_bool  IS NOT NULL THEN 1 ELSE 0 END) +
        (CASE WHEN val_text  IS NOT NULL THEN 1 ELSE 0 END) <= 1
    )
);

SELECT create_hypertable(
    'platform_data.telemetry',
    'time',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

-- Per-tag time-range access (Grafana). No separate BRIN(time): chunk exclusion
-- already prunes by time and a BRIN index only adds write cost here.
CREATE INDEX IF NOT EXISTS idx_telemetry_tag_time
    ON platform_data.telemetry (tag_serial, time DESC);

-- ---------------------------------------------------------------------------
-- 4. Raw MQTT staging table
--    Telegraf json_v2 writes time, topic, asset_id (optional), host and fields
--    (JSONB). Optional source_timestamp, sequence_number and quality_code may
--    be supplied by upstream processing.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS platform_data.mqtt_consumer (
    time             TIMESTAMPTZ NOT NULL,
    topic            TEXT NOT NULL,
    asset_id         TEXT,
    host             TEXT,
    source_timestamp TIMESTAMPTZ,
    sequence_number  BIGINT,
    quality_code     TEXT NOT NULL DEFAULT 'UNKNOWN'
        CHECK (quality_code IN ('GOOD', 'BAD', 'UNCERTAIN', 'UNKNOWN')),
    fields           JSONB NOT NULL
);

COMMENT ON TABLE platform_data.mqtt_consumer IS
    'Transient MQTT staging table. A BEFORE INSERT trigger routes fields into '
    'typed telemetry and returns NULL so the staging row is not retained.';

-- ---------------------------------------------------------------------------
-- 5. Ingestion trigger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform_data.route_telemetry_stage()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    r            RECORD;
    v_asset_id   TEXT;
    v_tag_serial BIGINT;
    v_tag_type   TEXT;
    v_hint_type  TEXT;
    v_float      DOUBLE PRECISION;
    v_bool       BOOLEAN;
    v_text       TEXT;
    v_quality    TEXT;
    v_source_ts  TIMESTAMPTZ;
BEGIN
    IF NEW.time IS NULL THEN
        RAISE EXCEPTION 'MQTT staging row has NULL time';
    END IF;

    IF NEW.fields IS NULL OR jsonb_typeof(NEW.fields) <> 'object'
       OR NEW.fields = '{}'::jsonb THEN
        RETURN NULL;
    END IF;

    v_asset_id := COALESCE(
        NULLIF(BTRIM(NEW.asset_id), ''),
        NULLIF(split_part(NEW.topic, '/', 2), '')
    );

    IF v_asset_id IS NULL
       OR v_asset_id = 'telemetry'
       OR length(v_asset_id) > 100
       OR position('.' IN v_asset_id) > 0 THEN
        RAISE WARNING 'Ignoring MQTT row with unusable asset id (%): topic=%',
                      COALESCE(NEW.asset_id, '<null>'), NEW.topic;
        RETURN NULL;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM platform_data.assets
                   WHERE asset_id = v_asset_id) THEN
        INSERT INTO platform_data.assets (asset_id, asset_name, location_zone)
        VALUES (v_asset_id, 'Auto-Registered: ' || v_asset_id, 'ZONE_UNKNOWN')
        ON CONFLICT (asset_id) DO NOTHING;
    END IF;

    v_quality   := COALESCE(NEW.quality_code, 'UNKNOWN');
    v_source_ts := COALESCE(NEW.source_timestamp, NEW.time);

    FOR r IN SELECT key, value FROM jsonb_each_text(NEW.fields) LOOP
        IF r.key IN ('asset_id', 'topic', 'host') THEN
            CONTINUE;
        END IF;

        IF r.key IS NULL OR btrim(r.key) = '' OR length(r.key) > 150 THEN
            RAISE WARNING 'Skipping invalid telemetry tag name for asset %',
                          v_asset_id;
            CONTINUE;
        END IF;

        SELECT t.tag_serial, t.data_type
          INTO v_tag_serial, v_tag_type
          FROM platform_data.asset_tags AS t
         WHERE t.asset_id = v_asset_id
           AND t.tag_name = r.key;

        IF NOT FOUND THEN
            SELECT h.data_type
              INTO v_hint_type
              FROM platform_data.tag_type_hints AS h
             WHERE h.asset_id = v_asset_id
               AND h.tag_name = r.key;

            IF v_hint_type IS NOT NULL THEN
                v_tag_type := v_hint_type;
            ELSIF r.value IS NULL THEN
                RAISE DEBUG 'Deferring registration of %.%: NULL value, no hint',
                            v_asset_id, r.key;
                CONTINUE;
            ELSIF lower(btrim(r.value)) IN
                  ('true','false','on','off','yes','no') THEN
                v_tag_type := 'boolean';
            ELSIF pg_input_is_valid(r.value, 'double precision') THEN
                IF r.value::double precision IN
                   ('NaN'::double precision,
                    'Infinity'::double precision,
                    '-Infinity'::double precision) THEN
                    RAISE DEBUG 'Deferring registration of %.%: non-finite, no hint',
                                v_asset_id, r.key;
                    CONTINUE;
                END IF;
                v_tag_type := 'float';
            ELSE
                v_tag_type := 'text';
            END IF;

            INSERT INTO platform_data.asset_tags
                (tag_id, asset_id, tag_name, data_type)
            VALUES
                (v_asset_id || '.' || r.key, v_asset_id, r.key, v_tag_type)
            ON CONFLICT (asset_id, tag_name) DO UPDATE
                SET tag_name = EXCLUDED.tag_name
            RETURNING tag_serial, data_type
                 INTO v_tag_serial, v_tag_type;
        END IF;

        v_float := NULL;
        v_bool  := NULL;
        v_text  := NULL;

        IF r.value IS NULL THEN
            NULL;  -- null observation
        ELSIF v_tag_type = 'float' THEN
            IF pg_input_is_valid(r.value, 'double precision') THEN
                v_float := r.value::double precision;
                IF v_float IN ('NaN'::double precision,
                               'Infinity'::double precision,
                               '-Infinity'::double precision) THEN
                    v_float := NULL;
                    v_text  := r.value;
                END IF;
            ELSE
                v_text := r.value;
            END IF;
        ELSIF v_tag_type = 'boolean' THEN
            IF lower(btrim(r.value)) IN ('true','1','on','yes') THEN
                v_bool := TRUE;
            ELSIF lower(btrim(r.value)) IN ('false','0','off','no') THEN
                v_bool := FALSE;
            ELSE
                v_text := r.value;
            END IF;
        ELSE
            v_text := r.value;
        END IF;

        INSERT INTO platform_data.telemetry
            (time, tag_serial, val_float, val_bool, val_text, source_host,
             source_timestamp, sequence_number, quality_code)
        VALUES
            (NEW.time, v_tag_serial, v_float, v_bool, v_text, NEW.host,
             v_source_ts, NEW.sequence_number, v_quality);
    END LOOP;

    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_route_telemetry
    ON platform_data.mqtt_consumer;

CREATE TRIGGER trg_route_telemetry
BEFORE INSERT ON platform_data.mqtt_consumer
FOR EACH ROW
EXECUTE FUNCTION platform_data.route_telemetry_stage();

-- ---------------------------------------------------------------------------
-- 6. Compression
-- ---------------------------------------------------------------------------
ALTER TABLE platform_data.telemetry SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'tag_serial',
    timescaledb.compress_orderby   = 'time DESC'
);

SELECT add_compression_policy(
    'platform_data.telemetry',
    INTERVAL '7 days',
    if_not_exists => TRUE
);

-- ---------------------------------------------------------------------------
-- 7. MinIO archival control and manifest
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS platform_data.telemetry_archive_manifest (
    chunk_schema    TEXT NOT NULL,
    chunk_name      TEXT NOT NULL,
    range_start     TIMESTAMPTZ NOT NULL,
    range_end       TIMESTAMPTZ NOT NULL,
    object_bucket   TEXT NOT NULL,
    object_key      TEXT NOT NULL,
    format          TEXT NOT NULL DEFAULT 'parquet'
                    CHECK (format IN ('parquet', 'csv')),
    schema_version  TEXT NOT NULL DEFAULT '2.3',
    compression     TEXT NOT NULL DEFAULT 'zstd',
    row_count       BIGINT,
    object_bytes    BIGINT,
    checksum_sha256 CHAR(64),
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'uploaded', 'verified', 'failed')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    uploaded_at     TIMESTAMPTZ,
    verified_at     TIMESTAMPTZ,
    dropped_at      TIMESTAMPTZ,
    error_message   TEXT,
    PRIMARY KEY (chunk_schema, chunk_name),
    UNIQUE (object_bucket, object_key),
    CHECK (range_end > range_start),
    CHECK (status <> 'verified' OR
           (checksum_sha256 IS NOT NULL AND row_count IS NOT NULL
            AND object_bytes IS NOT NULL AND verified_at IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_archive_manifest_status
    ON platform_data.telemetry_archive_manifest (status, range_end);

CREATE TABLE IF NOT EXISTS platform_data.telemetry_retention_config (
    config_id          SMALLINT PRIMARY KEY DEFAULT 1 CHECK (config_id = 1),
    retention_interval INTERVAL NOT NULL DEFAULT INTERVAL '365 days',
    archive_required   BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO platform_data.telemetry_retention_config
    (config_id, retention_interval, archive_required)
VALUES
    (1, INTERVAL '365 days', TRUE)
ON CONFLICT (config_id) DO NOTHING;

DROP TRIGGER IF EXISTS trg_retention_config_touch
    ON platform_data.telemetry_retention_config;
CREATE TRIGGER trg_retention_config_touch
    BEFORE UPDATE ON platform_data.telemetry_retention_config
    FOR EACH ROW EXECUTE FUNCTION platform_data.touch_updated_at();

COMMENT ON TABLE platform_data.telemetry_archive_manifest IS
    'Audit manifest for telemetry chunks exported and verified in MinIO. '
    'A verified manifest row is required before a chunk may be dropped.';

COMMENT ON TABLE platform_data.telemetry_retention_config IS
    'Operational retention target; enforced only after verified archival.';

CREATE OR REPLACE VIEW platform_data.telemetry_chunks_due_for_archive AS
SELECT c.chunk_schema,
       c.chunk_name,
       c.range_start,
       c.range_end,
       c.is_compressed,
       COALESCE(m.status = 'verified'
                AND m.range_start = c.range_start
                AND m.range_end   = c.range_end, FALSE) AS archive_verified,
       m.status AS manifest_status,
       m.object_bucket,
       m.object_key,
       m.checksum_sha256,
       m.row_count AS manifest_row_count
FROM timescaledb_information.chunks AS c
LEFT JOIN platform_data.telemetry_archive_manifest AS m
       ON m.chunk_schema = c.chunk_schema
      AND m.chunk_name   = c.chunk_name
WHERE c.hypertable_schema = 'platform_data'
  AND c.hypertable_name   = 'telemetry'
  AND c.range_end <= now() - (SELECT retention_interval
                              FROM platform_data.telemetry_retention_config
                              WHERE config_id = 1);

COMMENT ON VIEW platform_data.telemetry_chunks_due_for_archive IS
    'Chunks beyond retention. Worker must export, verify, mark verified, then '
    'call drop_verified_archived_chunks().';

CREATE OR REPLACE FUNCTION platform_data.drop_verified_archived_chunks(
    p_max_chunks INTEGER DEFAULT 10)
RETURNS TABLE (dropped_chunk TEXT,
               dropped_range_start TIMESTAMPTZ,
               dropped_range_end TIMESTAMPTZ)
LANGUAGE plpgsql
AS $$
DECLARE
    d        RECORD;
    v_rows   BIGINT;
BEGIN
    IF p_max_chunks IS NULL OR p_max_chunks < 1 THEN
        RAISE EXCEPTION 'p_max_chunks must be >= 1';
    END IF;

    FOR d IN
        SELECT v.*
          FROM platform_data.telemetry_chunks_due_for_archive AS v
         WHERE v.archive_verified
         ORDER BY v.range_start
         LIMIT p_max_chunks
    LOOP
        SELECT count(*)
          INTO v_rows
          FROM platform_data.telemetry AS t
         WHERE t.time >= d.range_start
           AND t.time <  d.range_end;

        IF v_rows IS DISTINCT FROM d.manifest_row_count THEN
            RAISE WARNING
              'Not dropping %: live rows % <> manifest rows % (re-export needed)',
              d.chunk_name, v_rows, d.manifest_row_count;
            CONTINUE;
        END IF;

        PERFORM drop_chunks('platform_data.telemetry',
                            older_than => d.range_end,
                            newer_than => d.range_start);

        UPDATE platform_data.telemetry_archive_manifest AS m
           SET dropped_at = now()
         WHERE m.chunk_schema = d.chunk_schema
           AND m.chunk_name   = d.chunk_name;

        dropped_chunk       := d.chunk_schema || '.' || d.chunk_name;
        dropped_range_start := d.range_start;
        dropped_range_end   := d.range_end;
        RETURN NEXT;
    END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION platform_data.drop_verified_archived_chunks(INTEGER)
    FROM PUBLIC;

CREATE OR REPLACE VIEW platform_data.tag_type_hint_mismatches AS
SELECT t.tag_serial,
       t.tag_id,
       t.data_type AS registered_type,
       h.data_type AS hinted_type,
       h.notes
FROM platform_data.asset_tags AS t
JOIN platform_data.tag_type_hints AS h
  ON h.asset_id = t.asset_id
 AND h.tag_name = t.tag_name
WHERE t.data_type <> h.data_type;

-- IMPORTANT: Deliberately do NOT install add_retention_policy(). It can drop
-- chunks without consulting the manifest and cause irreversible loss if MinIO
-- is unavailable. All drops go through drop_verified_archived_chunks().

COMMIT;

-- ---------------------------------------------------------------------------
-- 8. Post-install checks (run manually)
-- ---------------------------------------------------------------------------
-- Hypertable and chunk count:
-- SELECT hypertable_schema, hypertable_name, num_chunks
-- FROM timescaledb_information.hypertables
-- WHERE hypertable_schema = 'platform_data' AND hypertable_name = 'telemetry';
--
-- Compression policy present, and NO retention policy:
-- SELECT job_id, proc_name, hypertable_name, schedule_interval
-- FROM timescaledb_information.jobs
-- WHERE hypertable_schema = 'platform_data';
--
-- Retention target and chunks past it (no deletion occurs):
-- SELECT * FROM platform_data.telemetry_retention_config;
-- SELECT * FROM platform_data.telemetry_chunks_due_for_archive;
--
-- Registered tags, recent samples, hint disagreements:
-- SELECT * FROM platform_data.asset_tags ORDER BY tag_serial DESC LIMIT 20;
-- SELECT time, tag_serial, val_float, val_bool, val_text, quality_code
-- FROM platform_data.telemetry ORDER BY time DESC LIMIT 50;
-- SELECT * FROM platform_data.tag_type_hint_mismatches;
--
-- Samples that did not fit their registered type (stored in val_text):
-- SELECT t.tag_id, t.data_type, x.time, x.val_text
-- FROM platform_data.telemetry x
-- JOIN platform_data.asset_tags t USING (tag_serial)
-- WHERE x.val_text IS NOT NULL AND t.data_type <> 'text'
--   AND x.time > now() - interval '1 hour'
-- ORDER BY x.time DESC LIMIT 50;
--
-- Smoke test of the trigger (rolled back, leaves nothing behind):
-- BEGIN;
--   INSERT INTO platform_data.mqtt_consumer (time, topic, fields)
--   VALUES (now(), 'lab/test_bed_01/telemetry',
--           '{"temp_c": 85.2, "pump_on": true, "mode": "AUTO", "pressure": null}');
--   SELECT t.tag_id, t.data_type, x.val_float, x.val_bool, x.val_text
--   FROM platform_data.telemetry x JOIN platform_data.asset_tags t USING (tag_serial);
--   -- expect temp_c/float, pump_on/boolean, mode/text; pressure NOT registered
-- ROLLBACK;
