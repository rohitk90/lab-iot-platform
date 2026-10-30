# Lab IIoT Platform --- Central Server

Central-server deployment for the Lab Industrial IoT platform. It
receives telemetry from edge devices over MQTT, processes incoming JSON
into a typed time-series data model in TimescaleDB, and exposes
operational dashboards through Grafana.

> **Deployment note:** This README documents the intended V2.3 design
> and the operating procedures in the project notes. Before running
> commands, confirm that paths, service names, credentials, and script
> options match the checked-out repository and deployed `.env`. The
> deployed Compose file, SQL scripts, and shell scripts are the source
> of truth.

## Contents

1.  [Overview](#1-overview)
2.  [Architecture](#2-architecture)
3.  [Data flow](#3-data-flow)
4.  [Design decisions](#4-design-decisions)
5.  [Prerequisites](#5-prerequisites)
6.  [First-time deployment](#6-first-time-deployment)
7.  [Daily operations](#7-daily-operations)
8.  [Database model --- V2.3](#8-database-model--v23)
9.  [Backup and recovery](#9-backup-and-recovery)
10. [Troubleshooting](#10-troubleshooting)
11. [Maintenance schedule](#11-maintenance-schedule)
12. [Repository layout](#12-repository-layout)
13. [Related project](#13-related-project)

------------------------------------------------------------------------

## 1. Overview

The platform provides a central ingestion and visualization layer for
industrial assets such as biomass pyrolysis equipment and laboratory or
demonstration-plant systems.

**Core capabilities**

-   MQTT-based telemetry ingestion from edge devices.
-   Central message processing through Telegraf.
-   Time-series storage in TimescaleDB.
-   Asset and tag registration from incoming telemetry.
-   Typed storage for floating-point, Boolean, and text values.
-   Grafana dashboards for monitoring and analysis.
-   Persistent service storage and backup/restore procedures.

## 2. Architecture

``` text
┌──────────────────────────────┐
│ Edge device                  │
│ Raspberry Pi                 │
│                              │
│ Telegraf / S7 data collector │
└──────────────┬───────────────┘
               │ MQTT
               │ lab/<asset_id>/telemetry
               ▼
┌──────────────────────────────────────────────────────────────┐
│ Central server                                                │
│                                                              │
│  ┌────────────┐    ┌────────────────┐    ┌────────────────┐  │
│  │ EMQX       │───▶│ Telegraf       │───▶│ TimescaleDB    │  │
│  │ MQTT broker│    │ MQTT consumer  │    │ V2.3 schema    │  │
│  └────────────┘    └────────────────┘    └───────┬────────┘  │
│                                                  │           │
│                                           ┌──────▼───────┐   │
│                                           │ Grafana      │   │
│                                           │ Dashboards   │   │
│                                           └──────────────┘   │
│                                                              │
│  Supporting services: Nginx, MinIO, Redis                    │
└──────────────────────────────────────────────────────────────┘
```

  -----------------------------------------------------------------------
  Service                             Responsibility
  ----------------------------------- -----------------------------------
  EMQX                                MQTT broker for edge telemetry

  Telegraf                            Subscribes to MQTT topics and
                                      writes incoming data to TimescaleDB

  TimescaleDB                         Asset metadata, tag registry,
                                      staging data, and time-series
                                      telemetry

  Grafana                             Dashboards and telemetry
                                      exploration

  Nginx                               HTTP entry point / reverse proxy

  MinIO                               Object storage intended for
                                      archived data and other platform
                                      objects

  Redis                               Supporting in-memory service
  -----------------------------------------------------------------------

Actual ports and network exposure are defined by `docker-compose.yml`
and the server firewall. Inspect the deployed configuration rather than
assuming a port is private.

## 3. Data flow

1.  **Acquire:** Edge Telegraf reads configured Siemens S7 PLC tags.
2.  **Publish:** The edge device publishes JSON telemetry to the central
    MQTT broker using a topic such as `lab/<asset_id>/telemetry`.
3.  **Subscribe:** Central Telegraf subscribes to `lab/+/telemetry` and
    writes each message into `platform_data.mqtt_consumer`.
4.  **Transform:** The V2.3 database trigger processes the staging row:
    -   Identifies or registers the asset.
    -   Identifies or registers each telemetry tag.
    -   Applies a configured type hint for a new tag; otherwise infers
        its type from the first usable value.
    -   Writes typed observations to `platform_data.telemetry`.
    -   Returns `NULL` from the `BEFORE INSERT` trigger so the staging
        row is not retained.
5.  **Visualize:** Grafana queries telemetry and joins it to the tag
    registry to resolve tag names and asset metadata.

**Type-inference caution:** `1` and `0` are ambiguous because they can
represent either numbers or Boolean states. Configure explicit type
hints for PLC Boolean tags instead of relying on first-seen inference.

## 4. Design decisions

  -----------------------------------------------------------------------
  Decision                            Reason
  ----------------------------------- -----------------------------------
  Integer `tag_serial` in telemetry   Keeps the time-series foreign key
                                      compact compared with repeating a
                                      text tag identifier in every
                                      observation.

  Natural tag key based on asset and  Supports consistent registration of
  tag name                            tags for each asset.

  Typed value columns                 Stores numeric, Boolean, and text
                                      observations in appropriate
                                      columns.

  One-day TimescaleDB chunks          Provides manageable time partitions
                                      for time-series operations.

  Compression after seven days        Reduces storage for older, less
                                      frequently accessed chunks.

  No automatic telemetry retention    Old chunks should only be removed
  drop                                after the archive has been
                                      verified.

  Environment-based credentials       Keeps credentials out of
                                      source-controlled configuration
                                      files.
  -----------------------------------------------------------------------

The V2.3 schema includes an archive manifest and a controlled chunk-drop
function. The database objects alone do not mean that a MinIO archival
worker is deployed or running.

## 5. Prerequisites

The deployment notes specify this baseline:

-   Ubuntu Server (22.04 or 24.04 LTS are the documented tested
    versions).
-   Docker Engine and Docker Compose v2.
-   Static IP address or stable hostname on the plant/Lab network.
-   Storage sized for the expected telemetry rate, retention period, and
    backup requirements.
-   PostgreSQL client utilities (`pg_dump`, `pg_restore`, and optionally
    `pg_dumpall`).

Install PostgreSQL client tools if required:

``` bash
sudo apt update
sudo apt install -y postgresql-client
```

Install Docker using your organization's approved procedure. After
adding your account to the `docker` group, log out and back in before
relying on group membership.

## 6. First-time deployment

### 6.1 Clone the repository

``` bash
git clone git@github.com:<your-org>/lab-iot-platform.git
cd lab-iot-platform
```

Replace `<your-org>` with the actual GitHub organization or account.

### 6.2 Configure environment variables

``` bash
cp .env.example .env
nano .env
```

Set unique, strong values for all passwords and credentials. Keep `.env`
out of Git. Confirm that values used by Telegraf, EMQX, TimescaleDB,
Grafana, and MinIO agree with their service configurations.

Special characters may be interpreted by Docker Compose interpolation.
Quote or escape them correctly and validate the result.

### 6.3 Prepare persistent storage

If provided by the repository, run:

``` bash
sudo ./scripts/bootstrap-storage.sh
```

The documented persistent data layout is:

``` text
/var/lib/lab-platform/data/
├── timescaledb/
├── grafana/
├── emqx/
├── redis/
└── minio/
```

Use the checked-out bootstrap script as the source of truth for exact
paths and container UIDs/GIDs.

### 6.4 Validate and deploy

``` bash
docker compose config
./platform.sh deploy
```

The documented deployment workflow is intended to validate Compose
configuration, start services, wait for TimescaleDB readiness, and
verify the database schema. Inspect `platform.sh` to confirm the checks
implemented by your current version.

### 6.5 Verify services

``` bash
docker compose ps

docker logs lab_telegraf_server --tail 50
docker logs lab_timescaledb --tail 50

docker exec lab_timescaledb \
  pg_isready -U lab_admin -d lab_platform
```

List objects in the platform schema:

``` bash
docker exec -it lab_timescaledb \
  psql -U lab_admin -d lab_platform -c "
    SELECT table_name, table_type
    FROM information_schema.tables
    WHERE table_schema = 'platform_data'
    ORDER BY table_type, table_name;
  "
```

Compare the result with the actual V2.3 initialization SQL. An expected
object count alone does not prove that every schema object is correct.

### 6.6 Open Grafana

Open the URL configured for the deployment, for example:

``` text
http://<server-ip>/
```

Log in using the Grafana administrator credentials configured in `.env`.

The documented dashboard set is:

-   IIoT Explorer
-   Pyrolysis Overview
-   Pyrolysis Process Trends
-   Pyrolysis Motors & Drives
-   Pyrolysis Temperatures & Flows

Availability depends on the dashboard provisioning files in the deployed
repository.

### 6.7 Connect an edge device

The edge software is maintained in the related `lab-iot-device-main`
repository. Configure the PLC connection, central MQTT host, MQTT
credentials, and asset identifier using that repository's deployment
instructions.

After the first valid telemetry message, check whether the asset and
tags have been registered centrally.

## 7. Daily operations

### 7.1 Platform CLI

The documented `platform.sh` commands are:

  -----------------------------------------------------------------------
  Command                             Purpose
  ----------------------------------- -----------------------------------
  `./platform.sh setup`               Prepare persistent data and backup
                                      directories

  `./platform.sh deploy`              Start services and run deployment
                                      checks

  `./platform.sh status`              Display service status and selected
                                      logs

  `./platform.sh backup`              Run the configured backup workflow
  -----------------------------------------------------------------------

Run `./platform.sh` or inspect the script for the exact supported
commands.

### 7.2 Check container status and logs

``` bash
docker compose ps
docker logs -f lab_timescaledb --tail 50
docker logs -f lab_telegraf_server --tail 50
```

### 7.3 Check recent telemetry ingestion

``` bash
docker exec -it lab_timescaledb \
  psql -U lab_admin -d lab_platform -c "
    SELECT COUNT(*) AS rows_last_minute
    FROM platform_data.telemetry
    WHERE time > NOW() - INTERVAL '1 minute';
  "
```

The expected row count depends on connected assets, configured tags,
publish interval, filtering, and data quality. Treat it as a health
indicator, not a universal fixed threshold.

### 7.4 Check registered assets and tags

``` bash
docker exec -it lab_timescaledb \
  psql -U lab_admin -d lab_platform -c "
    SELECT asset_id, COUNT(*) AS tag_count
    FROM platform_data.asset_tags
    GROUP BY asset_id
    ORDER BY asset_id;
  "
```

### 7.5 Check the staging table

``` bash
docker exec -it lab_timescaledb \
  psql -U lab_admin -d lab_platform -c "
    SELECT COUNT(*) AS staging_rows
    FROM platform_data.mqtt_consumer;
  "
```

With the documented `BEFORE INSERT` trigger returning `NULL`,
successfully processed rows should not accumulate in the staging table.
A persistent or increasing count warrants investigation of trigger
errors and database logs.

### 7.6 Restart one service

``` bash
docker compose restart telegraf_server
```

Use the actual Compose service name; a container name and a Compose
service name are not necessarily identical.

## 8. Database model --- V2.3

The schema is under `platform_data`. This is a conceptual overview; the
deployed `init.sql` is authoritative for exact columns, constraints,
indexes, and functions.

### 8.1 `platform_data.assets`

Asset registry. Assets can be registered when telemetry arrives.

  Field             Purpose
  ----------------- --------------------------------
  `asset_id`        Asset identifier / primary key
  `asset_name`      Human-readable asset name
  `location_zone`   Asset location or zone
  `is_active`       Active/inactive state

### 8.2 `platform_data.asset_tags`

Tag registry linking each tag to an asset.

  Field          Purpose
  -------------- ------------------------------------------
  `tag_serial`   Integer surrogate key used by telemetry
  `tag_id`       Unique human-readable tag identifier
  `asset_id`     Asset foreign key
  `tag_name`     Tag name within the asset
  `data_type`    Registered type: float, boolean, or text

### 8.3 `platform_data.telemetry`

Time-series hypertable containing typed observations.

  -----------------------------------------------------------------------
  Field                               Purpose
  ----------------------------------- -----------------------------------
  `time`                              Observation timestamp /
                                      partitioning time

  `tag_serial`                        Foreign key to `asset_tags`

  `val_float`                         Floating-point value

  `val_bool`                          Boolean value

  `val_text`                          Text value

  `quality_code`                      Quality state such as GOOD, BAD,
                                      UNCERTAIN, or UNKNOWN
  -----------------------------------------------------------------------

The V2.3 design uses one-day chunks and an index on the tag key and
descending time. Confirm exact definitions in the SQL schema.

### 8.4 `platform_data.tag_type_hints`

Optional type hints for tags. Use these where automatic inference would
be ambiguous, especially for Boolean signals represented as `0` and `1`.

### 8.5 `platform_data.mqtt_consumer`

Transient staging table for incoming MQTT messages. The V2.3 trigger
transforms each inserted message into typed telemetry and discards the
staging row after successful processing.

### 8.6 Type registration

-   Existing tags retain their registered type.
-   A configured type hint is used when a tag is first registered.
-   Otherwise, the first usable value is used for type inference.
-   Boolean words such as `true`, `false`, `on`, `off`, `yes`, and `no`
    can be recognized as Boolean-like values.
-   Numeric values can be inferred as floating point.
-   Other values can be stored as text.
-   `NULL`, `NaN`, and infinity values may defer registration until a
    usable value arrives.

Because `1` and `0` can represent either numbers or Boolean states,
define hints for such tags before relying on first-seen inference.

### 8.7 Compression and archival retention

The documented policy compresses chunks older than seven days. The V2.3
design intentionally does **not** install an automatic data-retention
policy that drops old telemetry.

The archive manifest tracks archive metadata and verification status.
The controlled chunk-drop function is intended to remove only chunks
whose archive manifest is verified and whose recorded row count matches
the live chunk count.

> **Archival safety:** A row-count check by itself does not protect
> against late-arriving or backfilled telemetry being inserted after the
> check. Before enabling automated chunk deletion, implement and test an
> ingestion cutoff/watermark or a coordinated archival process that
> prevents writes to the chunk during export, verification, and
> deletion. Do not schedule the chunk-drop function until that
> protection is in place.

The schema's default archival retention setting is 365 days. Backup
retention is a separate policy and must be configured independently.

## 9. Backup and recovery

### 9.1 Backup strategy

Where practical, maintain at least two copies:

1.  A local backup on a separate, adequately sized filesystem.
2.  A second copy on removable USB storage or a NAS, kept separate from
    the server.

A logical database backup and a service-data archive serve different
purposes. The database dump captures PostgreSQL database objects and
data; the service archive captures selected persistent service
directories. Confirm that the TimescaleDB data directory is excluded
from the tar archive when the database is backed up logically, and that
all required non-database service data is included.

### 9.2 Run a manual backup

If provided by the repository:

``` bash
./platform.sh backup
```

Or run the backup script directly:

``` bash
./scripts/backup.sh
```

The exact destination, retention period, free-space checks, globals
dump, checksum generation, and archive contents depend on the current
script configuration. Review `scripts/backup.sh` before scheduling it.

Example destination locations:

``` text
/var/lib/lab-platform/backups/   # local backup filesystem/directory
/mnt/usb-backup/lab-iot/         # removable USB/NAS mount
```

Do not write to a USB/NAS path unless the filesystem is mounted.
Otherwise, the backup may be written to the server's local root
filesystem.

### 9.3 Verify backup files

If the backup set contains a SHA-256 manifest:

``` bash
cd /path/to/backup-set
sha256sum -c MANIFEST.sha256
```

For a PostgreSQL custom-format dump:

``` bash
pg_restore --list db_dump.dump >/dev/null
```

For a gzip tar archive:

``` bash
tar -tzf data_backup.tar.gz >/dev/null
```

A checksum or archive listing is not a substitute for a test restore.

### 9.4 Restore

If the repository provides a restore script:

``` bash
./scripts/restore-db.sh /path/to/backup-set
```

Read the script before running it. A restore may drop or replace
existing schema objects and can cause data loss. Confirm the target
database, backup integrity, and recovery point before proceeding. Prefer
testing the restore in a separate environment first.

### 9.5 Off-site copy

After verifying the backup, copy it to a separately mounted USB/NAS
destination. Example:

``` bash
rsync -a /var/lib/lab-platform/backups/ /mnt/usb-backup/lab-iot/
```

Use `--delete` only when you deliberately want the destination to mirror
the source; it can remove files from the destination. Confirm the mount
before synchronization.

### 9.6 Backup retention versus telemetry retention

These are different policies:

-   **Backup retention:** how long backup sets are kept (for example, 7
    or 30 days).
-   **Telemetry retention:** how long live telemetry remains in
    TimescaleDB before eligible chunks may be archived and dropped (the
    documented V2.3 default is 365 days).

Changing backup retention does not change database telemetry retention.

## 10. Troubleshooting

### 10.1 Grafana dashboard shows "No Data"

Check that the dashboard query joins telemetry to the tag registry using
`tag_serial`.

``` sql
SELECT t.time, t.val_float
FROM platform_data.telemetry AS t
JOIN platform_data.asset_tags AS a
  ON a.tag_serial = t.tag_serial
WHERE a.tag_id = 'biomass_pyrolyser_01.pyrolyzer_heater_power'
ORDER BY t.time;
```

Also verify the selected time range, asset/tag identifier, and value
column (`val_float`, `val_bool`, or `val_text`).

### 10.2 Telegraf reports MQTT "not Authorized"

Check:

-   EMQX authentication is enabled and the configured Telegraf account
    exists.
-   The username/password in the central Telegraf container match the
    EMQX credentials.
-   MQTT authorization rules permit subscription to `lab/+/telemetry`.
-   The central Telegraf container has received updated environment
    variables after `.env` changes.

Inspect logs without printing passwords:

``` bash
docker logs lab_telegraf_server --tail 100
docker logs <emqx-container-name> --tail 100
```

After correcting credentials or environment values, recreate the
affected service if necessary:

``` bash
docker compose up -d --force-recreate telegraf_server
```

Do not disable MQTT authentication as a troubleshooting shortcut.

### 10.3 PostgreSQL password authentication fails

The password in `.env` may differ from the password stored inside an
already initialized database. Updating `.env` does not automatically
change an existing PostgreSQL role password.

If you have authorized database-administrator access, reset the role
password using your approved procedure, then update the matching
application configuration and recreate dependent containers as needed.

Do not wipe the TimescaleDB data directory to resolve a password
mismatch unless you intentionally want to destroy and reinitialize the
database.

### 10.4 TimescaleDB reports "permission denied"

Check persistent directory ownership and permissions against the UID/GID
expected by the deployed TimescaleDB image. Re-run the repository's
storage bootstrap procedure if appropriate:

``` bash
sudo ./scripts/bootstrap-storage.sh
```

Then recreate only the affected service if required:

``` bash
docker compose up -d --force-recreate timescaledb
```

Do not recursively change ownership to an assumed UID without checking
the image and bootstrap script.

### 10.5 Grafana reports "Datasource not found"

Check that the provisioned datasource UID matches the UID referenced by
dashboards.

``` bash
grep -n 'uid:' infra/grafana/provision/datasources/ds-timescale.yaml
```

Then inspect Grafana logs and restart Grafana if required:

``` bash
docker compose restart grafana
docker logs lab_grafana --tail 100
```

### 10.6 Backup fails with permission or space errors

Check:

``` bash
df -h
mount
ls -ld /var/lib/lab-platform/data
```

The backup process must be able to read the selected service-data
directories and write to the backup destination. If backup runs from
cron, verify the cron user's permissions and environment. Prefer
narrowly scoped, reviewed privileges over broad passwordless `sudo`
access.

### 10.7 Disk usage is increasing

Check database size:

``` bash
docker exec lab_timescaledb \
  psql -U lab_admin -d lab_platform -c "
    SELECT pg_size_pretty(pg_database_size('lab_platform'));
  "
```

Inspect TimescaleDB jobs:

``` bash
docker exec lab_timescaledb \
  psql -U lab_admin -d lab_platform -c "
    SELECT job_id, application_name, schedule_interval, next_start
    FROM timescaledb_information.jobs
    ORDER BY job_id;
  "
```

Also check Docker volumes, logs, MinIO usage, backup directories, and
incoming telemetry rates. Verify that compression jobs are succeeding.
Do not delete chunks as an ad hoc response to low disk space; first
confirm that a verified archive and safe deletion workflow are in place.

## 11. Maintenance schedule

  -----------------------------------------------------------------------
  Frequency                           Task
  ----------------------------------- -----------------------------------
  Daily                               Confirm containers are healthy and
                                      check ingestion/backup job results.

  Weekly                              Review disk usage and recent backup
                                      sets; copy a verified backup to
                                      USB/NAS.

  Monthly                             Review registered assets/tags,
                                      inspect database growth, and
                                      perform a restore test in a
                                      non-production environment.

  Quarterly                           Review credential rotation, Docker
                                      image updates, backup recovery
                                      procedures, and archival/retention
                                      settings.
  -----------------------------------------------------------------------

Record maintenance results and configuration changes in the project
change log.

## 12. Repository layout

The following is the documented intended layout. The actual repository
may contain additional files or different names.

``` text
lab-iot-platform/
├── README.md
├── docker-compose.yml
├── platform.sh
├── .env.example
├── infra/
│   ├── grafana/
│   │   └── provision/
│   │       ├── datasources/
│   │       │   └── ds-timescale.yaml
│   │       └── dashboards/
│   │           ├── dashboards.yaml
│   │           ├── iiot-explorer.json
│   │           ├── pyrolysis-overview.json
│   │           ├── pyrolysis-trends.json
│   │           ├── pyrolysis-motors.json
│   │           └── pyrolysis-temps-flows.json
│   ├── nginx/
│   │   └── nginx.conf
│   ├── telegraf_server/
│   │   └── telegraf.conf
│   └── timescaledb/
│       └── init.sql
└── scripts/
    ├── backup.sh
    ├── bootstrap-storage.sh
    └── restore-db.sh
```

## 13. Related project

-   **`lab-iot-device-main`** --- edge-device software, including the
    Telegraf S7 reader, PLC simulator, and edge-side telemetry
    publishing components.

------------------------------------------------------------------------

**Platform schema reference:** V2.3\
**Document purpose:** Deployment, operations, data-model orientation,
backup/recovery, and troubleshooting.\
**Last reviewed:** 2026-10-31

> Keep this README synchronized with the actual Compose file, SQL
> initialization scripts, backup/restore scripts, and deployed
> environment. Update it whenever service names, ports, paths, schema
> versions, or operating procedures change.
