# Central Laboratory IIoT Data Core

A Docker Compose–based data platform for the laboratory network, providing MQTT messaging, time-series telemetry storage, object storage, dashboards, and an HTTP entry point.

> **Deployment scope:** Phase 1A — central data core for the R&D laboratory network.

## Contents

- [Architecture at a glance](#architecture-at-a-glance)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Database initialization](#database-initialization)
- [Day-to-day operations](#day-to-day-operations)
- [Backups and recovery](#backups-and-recovery)
- [Security notes](#security-notes)

## Architecture at a glance

| Service | Purpose | Default port(s) |
|---|---|---:|
| **EMQX** | MQTT broker for device and service telemetry | `1883`, `18083` |
| **TimescaleDB** | PostgreSQL database and time-series telemetry | `5432` |
| **Telegraf** | Ingests MQTT telemetry into TimescaleDB | — |
| **Redis** | In-memory data store with persistence enabled | `6379` |
| **MinIO** | S3-compatible object storage | `9000`, `9001` |
| **Grafana OSS** | Telemetry dashboards | `3000` |
| **NGINX** | HTTP entry point / reverse proxy | `80` |

Ports shown are the Compose port mappings. Restrict access using the host firewall and AWS security groups; do not expose service administration ports publicly.

## Repository layout

```text
lab-iot-platform/
├── .env                         # Local secrets; do not commit
├── .env.example                 # Configuration template
├── docker-compose.yml
├── platform.sh                  # Optional operations wrapper
├── scripts/
│   ├── bootstrap-storage.sh     # Prepare persistent host directories
│   └── backup.sh                # Database and service-data backup
└── infra/
    ├── timescaledb/
    │   └── init.sql             # First-time database initialization
    ├── telegraf_server/
    │   └── telegraf.conf
    ├── nginx/
    │   └── nginx.conf
    └── grafana/
        └── provision/
```

## Prerequisites

- Ubuntu server with Docker Engine and the Docker Compose plugin.
- Git and this repository cloned on the server.
- Network access to the required container image registries.
- Firewall and AWS security group rules limited to trusted clients and administrators.

## Quick start

Run all commands from the repository root.

### 1. Create your environment file

```bash
cp .env.example .env
nano .env
```

Set unique, strong passwords. These are the variables currently used by the Compose configuration:

```dotenv
DATA_PATH=/var/lib/lab-platform/data
POSTGRES_DB=lab_platform
POSTGRES_USER=lab_admin
POSTGRES_PASSWORD=REPLACE_WITH_A_UNIQUE_STRONG_SECRET
MINIO_ROOT_USER=minio_admin
MINIO_ROOT_PASSWORD=REPLACE_WITH_A_UNIQUE_STRONG_SECRET
TELEGRAF_MQTT_USER=telegraf
TELEGRAF_MQTT_PASSWORD=REPLACE_WITH_A_UNIQUE_STRONG_SECRET
```

Check that Git ignores the real environment file:

```bash
git check-ignore .env
```

If that command prints nothing, add `.env` to `.gitignore` before proceeding.

### 2. Validate configuration

```bash
docker compose config --quiet
```

Fix any configuration errors before starting the stack.

### 3. Prepare persistent storage

Do this **before the first container startup**:

```bash
chmod +x scripts/bootstrap-storage.sh scripts/backup.sh
sudo ./scripts/bootstrap-storage.sh
```

The bootstrap script reads `DATA_PATH` from `.env` and sets service-specific ownership and restrictive permissions.

> **Do not use `chmod -R 777` on the data directory.** It gives every local user write access and is not needed for this setup.

### 4. Start the services

```bash
docker compose up -d
docker compose ps
```

Check database readiness:

```bash
docker compose exec -T timescaledb sh -lc \
  'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

View service logs if a container is unhealthy or repeatedly restarting:

```bash
docker compose logs --tail=100
```

## Database initialization

The Compose file mounts `infra/timescaledb/init.sql` into the PostgreSQL initialization directory. The image runs this SQL automatically **only when the database data directory is initialized for the first time and is empty**.

The initialization SQL creates the `platform_data` schema and its asset/tag registries, telemetry hypertable, type hints, staging table, routing function, and trigger.

**It does not rerun** on ordinary restarts or container recreation when the existing database volume/data directory is retained. If the database was initialized before this SQL file was mounted, the file will not be applied automatically.

Verify that the telemetry table exists:

```bash
docker compose exec -T timescaledb sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT to_regclass('\''platform_data.telemetry'\'') AS telemetry_table;"'
```

Check database logs:

```bash
docker compose logs --tail=200 timescaledb
```

> **Important:** Do not delete the TimescaleDB data directory just to force initialization. That can permanently destroy stored telemetry. Inspect the database and plan any manual SQL application or migration before changing a live instance.

## Day-to-day operations

### Check status

```bash
docker compose ps
```

### Follow logs

```bash
docker compose logs -f
docker compose logs -f emqx
docker compose logs -f timescaledb
docker compose logs -f telegraf_server
```

Press `Ctrl+C` to stop following logs; this does not stop the containers.

### Apply a repository update

Review changes first, especially changes to Compose configuration, credentials, and SQL. Then:

```bash
git pull
docker compose config --quiet
docker compose up -d
docker compose ps
```

A Git pull does not apply database schema changes to an already initialized database. Handle schema changes as explicit, reviewed migrations.

### Optional `platform.sh` wrapper

If `platform.sh` is present in the repository:

```bash
chmod +x platform.sh
./platform.sh setup
./platform.sh deploy
./platform.sh status
./platform.sh backup
```

- `setup` — prepare host storage.
- `deploy` — validate configuration and start services.
- `status` — show container status and relevant database logs.
- `backup` — invoke the backup script.

Review the script and its paths before using it on a server.

## Backups and recovery

The supplied `scripts/backup.sh`:

- Creates a logical PostgreSQL/TimescaleDB dump using `pg_dump`.
- Archives persistent service data while excluding the TimescaleDB physical data directory.
- Validates the generated backup files.
- Writes a `BACKUP_COMPLETE` marker after successful validation.
- Retains timestamped backups for 30 days, according to the script's configured policy.

### Run a backup manually

After the database is ready, test a backup:

```bash
chmod +x scripts/backup.sh
sudo ./scripts/backup.sh
sudo find /var/lib/lab-platform/backups -maxdepth 2 -type f -ls
```

The supplied script writes backups to `/var/lib/lab-platform/backups`.

> **Recovery warning:** A backup stored on the same host filesystem does not protect against loss of the EC2 instance or its disk. Copy verified backups to separate, access-controlled storage (for example, an appropriately secured S3 bucket) and test restoration periodically.

### Schedule a daily backup

Only schedule this after a manual backup succeeds:

```bash
sudo crontab -e
```

Add the following line, updating the repository path if necessary:

```cron
0 2 * * * /home/ubuntu/lab-iot-platform/scripts/backup.sh >> /var/log/lab-platform-backup.log 2>&1
```

This runs at 02:00 in the server's configured timezone. Check the timezone and backup log with:

```bash
timedatectl
sudo tail -n 100 /var/log/lab-platform-backup.log
```

## Security notes

- Never commit `.env`, passwords, private keys, or backup files.
- If credentials have been committed or exposed, rotate them; adding `.env` to `.gitignore` does not remove secrets from Git history.
- Restrict inbound ports with the host firewall and AWS security groups.
- Use HTTPS and appropriate authentication for any service exposed beyond a trusted lab network.
- Treat backups as sensitive data and restrict their permissions and access.
- A container restart policy is not a backup, a health check, or a disaster-recovery plan.
