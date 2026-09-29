CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
CREATE SCHEMA IF NOT EXISTS platform_data;

CREATE TABLE platform_data.assets (
    asset_id VARCHAR(50) PRIMARY KEY,
    asset_name VARCHAR(100) NOT NULL,
    location_zone VARCHAR(50) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE platform_data.asset_tags (
    tag_id VARCHAR(100) PRIMARY KEY,
    asset_id VARCHAR(50) REFERENCES platform_data.assets(asset_id) ON DELETE CASCADE,
    tag_name VARCHAR(100) NOT NULL,
    data_type VARCHAR(20) NOT NULL CHECK (data_type IN ('float', 'boolean', 'text'))
);

CREATE TABLE platform_data.telemetry (
    time TIMESTAMP WITH TIME ZONE NOT NULL,
    tag_id VARCHAR(100) REFERENCES platform_data.asset_tags(tag_id),
    val_float DOUBLE PRECISION,
    val_bool BOOLEAN,
    val_text TEXT
);

SELECT create_hypertable('platform_data.telemetry', 'time', chunk_time_interval => INTERVAL '7 days');
CREATE INDEX idx_telemetry_tag_time ON platform_data.telemetry (tag_id, time DESC);
