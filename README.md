# Central Laboratory IIoT Data Core

A Docker Compose–based platform for laboratory IoT data collection, time-series storage, MQTT messaging, object storage, and visualization.

**Phase 1A:** Central data infrastructure for the R&D laboratory network.

---

## 🏗️ Architecture Overview

| Service | Purpose | Ports |
|---|---|---|
| **EMQX** | MQTT broker for telemetry | `1883`, `18083` |
| **TimescaleDB** | PostgreSQL and time-series storage | `5432` |
| **Telegraf** | MQTT telemetry ingestion into TimescaleDB | — |
| **Redis** | In-memory data store with persistence | `6379` |
| **MinIO** | S3-compatible object storage | `9000`, `9001` |
| **Grafana OSS** | Dashboards and monitoring | `3000` |
| **NGINX** | HTTP entry point / reverse proxy | `80` |

> **Security:** Do not expose database, broker, storage, or administration ports publicly. Restrict access using AWS security groups and host firewall rules.

## 📁 Repository Structure

```text
lab-iot-platform/
├── .env
├── .env.example
├── docker-compose.yml
├── platform.sh
├── scripts/
│   ├── bootstrap-storage.sh
│   └── backup.sh
└── infra/
    ├── timescaledb/
    │   └── init.sql
    ├── telegraf_server/
    │   └── telegraf.conf
    ├── nginx/
    │   └── nginx.conf
    └── grafana/
        └── provision/
```

## ⚙️ Prerequisites

- Ubuntu server
- Docker Engine and Docker Compose plugin
- Git
- Network access to container image registries

## 🚀 Quick Start

Run these commands from the repository root.

### 1. Configure environment variables

```bash
cp .env.example .env
nano .env
```

Set unique, strong passwords in `.env` for PostgreSQL, MinIO, and MQTT.

Verify that `.env` is ignored by Git:

```bash
git check-ignore .env
```

If no output appears, add `.env` to `.gitignore` before proceeding.

### 2. Validate the Compose configuration

```bash
docker compose config --quiet
```

### 3. Initialize persistent storage

Run before starting the services for the first time:

```bash
chmod +x scripts/bootstrap-storage.sh scripts/backup.sh
sudo ./scripts/bootstrap-storage.sh
```

> Do not use `chmod -R 777` on persistent data directories. The bootstrap script configures service-specific ownership and permissions.

### 4. Start the platform

```bash
docker compose up -d
docker compose ps
```

Check database readiness:

```bash
docker compose exec -T timescaledb sh -lc \
  'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

View logs:

```bash
docker compose logs --tail=100
```

## 🗄️ Database Initialization

The file `infra/timescaledb/init.sql` is mounted into PostgreSQL's initialization directory.

It runs automatically **only when PostgreSQL initializes an empty data directory for the first time**.

The SQL creates the `platform_data` schema, asset and tag registries, telemetry hypertable, staging table, and telemetry-routing trigger.

Check that the telemetry table exists:

```bash
docker compose exec -T timescaledb sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT to_regclass('\''platform_data.telemetry'\'');"'
```

> **Important:** Restarting or recreating the container does not rerun the initialization SQL against an existing database. Never delete the database data directory just to rerun initialization; this may destroy telemetry.

## 🔧 Day-to-Day Operations

| Task | Command |
|---|---|
| Check service status | `docker compose ps` |
| Start services | `docker compose up -d` |
| Stop services | `docker compose down` |
| View all logs | `docker compose logs -f` |
| View database logs | `docker compose logs -f timescaledb` |
| View MQTT ingestion logs | `docker compose logs -f telegraf_server` |
| Validate configuration | `docker compose config --quiet` |

To apply a repository update:

```bash
git pull
docker compose config --quiet
docker compose up -d
```

Review configuration and database changes before applying updates.

### Optional platform wrapper

If `platform.sh` is present in the repository:

```bash
./platform.sh setup
./platform.sh deploy
./platform.sh status
./platform.sh backup
```

Review the script before running it and ensure its expected paths match your repository.

## 💾 Backups and Recovery

The supplied `scripts/backup.sh` creates a logical PostgreSQL backup, archives persistent service data excluding the TimescaleDB physical data directory, validates backup files, and applies the retention policy configured in the script.

Run a manual backup after confirming that the database is healthy:

```bash
sudo ./scripts/backup.sh
```

The current script writes backups under:

```text
/var/lib/lab-platform/backups
```

### Schedule a daily backup

After successfully testing a manual backup:

```bash
sudo crontab -e
```

Add the following line, adjusting the repository path if necessary:

```cron
0 2 * * * /home/ubuntu/lab-iot-platform/scripts/backup.sh >> /var/log/lab-platform-backup.log 2>&1
```

This schedules the backup at 02:00 in the server's configured timezone.

> **Disaster recovery:** Backups stored only on the EC2 host do not protect against loss of the instance or its disk. Copy verified backups to separate, access-controlled storage and periodically test restoration.

## 🔐 Security Checklist

- [ ] Use unique, strong passwords in `.env`.
- [ ] Ensure `.env` is excluded from Git.
- [ ] Restrict inbound ports using AWS security groups and the host firewall.
- [ ] Use HTTPS and authentication for externally accessible services.
- [ ] Restrict access to backups and persistent data.
- [ ] Test backup restoration periodically.
- [ ] Review credentials and access controls for EMQX, Grafana, and MinIO.

---

**Technology stack:** Docker Compose · EMQX · TimescaleDB · Telegraf · Redis · MinIO · Grafana OSS · NGINX
