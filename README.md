Central Laboratory Industrial IoT (IIoT) Data Core Platform
This repository deploys the Phase 1A central data core for the R&D laboratory network. It provides MQTT messaging, time-series telemetry storage, object storage, dashboards, and an NGINX entry point for laboratory clients.
Platform services
The current docker-compose.yml defines:
- TimescaleDB/PostgreSQL — telemetry database and schema
- EMQX — MQTT broker
- Redis — persistent Redis data
- MinIO — object storage
- Grafana OSS — dashboards
- NGINX — HTTP proxy
- Telegraf — MQTT-to-database ingestion
Repository layout
lab-iot-platform/
├── .env                         # Local secrets/configuration; never commit
├── .env.example                 # Safe configuration template; no real secrets
├── docker-compose.yml
├── platform.sh                  # Operational command wrapper (if installed)
├── scripts/
│   ├── bootstrap-storage.sh     # One-time host storage setup
│   └── backup.sh                # Database + service-data backup
└── infra/
    ├── timescaledb/
    │   └── init.sql             # First-time database initialization
    ├── telegraf_server/
    │   └── telegraf.conf
    ├── nginx/
    │   └── nginx.conf
    └── grafana/
        └── provision/
Prerequisites
- Ubuntu server with Docker Engine and the Docker Compose plugin installed.
- Git and the repository cloned onto the server.
- Access to the required image registries.
- Inbound network access restricted to trusted laboratory clients and administrators.
First-time deployment
Run these commands from the repository root.
1. Configure .env
cp .env.example .env
nano .env
Set strong, unique values for every password and credential. At minimum, the current Compose file uses:
DATA_PATH=/var/lib/lab-platform/data
POSTGRES_DB=lab_platform
POSTGRES_USER=lab_admin
POSTGRES_PASSWORD=REPLACE_WITH_A_UNIQUE_STRONG_SECRET
MINIO_ROOT_USER=minio_admin
MINIO_ROOT_PASSWORD=REPLACE_WITH_A_UNIQUE_STRONG_SECRET
TELEGRAF_MQTT_USER=telegraf
TELEGRAF_MQTT_PASSWORD=REPLACE_WITH_A_UNIQUE_STRONG_SECRET
These are example values, not production secrets. Keep the real .env out of Git:
git check-ignore .env
If the command returns no output, add .env to .gitignore. If a real .env has already been committed, ignoring it is not enough to remove it from Git history or tracking; remove it from tracking and rotate exposed credentials.
2. Validate the Compose configuration
docker compose config --quiet
Resolve any missing environment variables or invalid Compose settings before starting services.
3. Prepare persistent storage — before starting containers
The bootstrap script creates the host bind-mount directories and sets service-specific ownership and restrictive permissions:
chmod +x scripts/bootstrap-storage.sh scripts/backup.sh
sudo ./scripts/bootstrap-storage.sh
The script reads DATA_PATH from .env; its default is /var/lib/lab-platform/data.

Do not run chmod -R 777 on the data directory. It grants all local users write access and is not required by this setup.
4. Start the stack
docker compose up -d
docker compose ps
The Compose file sets restart: always on its services. Docker will restart containers after exits and when the Docker daemon starts, but this does not replace backups, database migrations, or storage setup.
Database initialization: how init.sql runs
The Compose file mounts:
- ./infra/timescaledb/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
The TimescaleDB image uses the PostgreSQL entrypoint initialization mechanism. It runs scripts in /docker-entrypoint-initdb.d/ when initializing a new, empty database data directory.

Important behavior:
- On a first initialization, the SQL creates the platform_data schema, asset/tag registries, telemetry hypertable, indexes, type hints, staging table, routing function, and trigger.
- On container restart or recreation with the existing data directory retained, the initialization SQL is not run again.
- If the database data directory already existed before the SQL mount was added, the script will not automatically run against that existing database.
- Do not delete the database directory just to force initialization; doing so can destroy persisted data.
Check the logs:
docker compose logs timescaledb
Check that TimescaleDB is ready:
docker compose exec -T timescaledb sh -lc \
  'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
Check that the extension and telemetry table exist:
docker compose exec -T timescaledb sh -lc \
  'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT extname FROM pg_extension WHERE extname = '\''timescaledb'\'';"'

docker compose exec -T timescaledb sh -lc \
  'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT to_regclass('\''platform_data.telemetry'\'') AS telemetry_table;"'
If initialization failed or the database existed already, inspect the logs and schema before deciding whether to apply SQL manually. Do not blindly rerun initialization on a live database.
Routine operations
View service status
docker compose ps
View logs
docker compose logs --tail=100
docker compose logs --tail=100 timescaledb
docker compose logs --tail=100 telegraf_server
Deploy a code/configuration update
Review the changes first, especially Compose, database, and environment changes. Then:
git pull
docker compose config --quiet
docker compose up -d
docker compose ps
A git pull does not automatically apply future database migrations. Plan and validate schema changes separately.
Optional operational wrapper
If platform.sh exists in the repository, it can provide convenient commands:
chmod +x platform.sh
./platform.sh setup
./platform.sh deploy
./platform.sh status
./platform.sh backup
Use setup for initial storage preparation, deploy to validate and start services, status for a quick check, and backup to run a backup. The wrapper does not replace reviewing deployment changes or verifying backup restores.
Backups
The current scripts/backup.sh is designed to:
- Create a PostgreSQL/TimescaleDB logical dump using pg_dump.
- Archive persistent service data while excluding the TimescaleDB physical data directory.
- Validate the generated archive files.
- Write a BACKUP_COMPLETE marker after successful validation.
- Remove old timestamp-named backup directories beyond its configured retention period (30 days in the supplied script).
Run a first backup manually after the database is ready:
chmod +x scripts/backup.sh
sudo ./scripts/backup.sh
sudo find /var/lib/lab-platform/backups -maxdepth 2 -type f -ls
The script currently writes backups to /var/lib/lab-platform/backups. The backup is on the same host filesystem as the platform data, so it does not protect against loss of the EC2 instance or its disk. For disaster recovery, copy verified backup sets to a separate location such as a suitably secured S3 bucket, and periodically test restoring them.
Schedule a daily backup
After a manual backup succeeds, edit root's crontab:
sudo crontab -e
Add the following line, adjusting the repository path if it differs:
0 2 * * * /home/ubuntu/lab-iot-platform/scripts/backup.sh >> /var/log/lab-platform-backup.log 2>&1
This runs at 02:00 in the server's configured timezone. Confirm the timezone with:
timedatectl
Check the log:
sudo tail -n 100 /var/log/lab-platform-backup.log
Access and security
The current Compose file publishes service ports including PostgreSQL 5432, MQTT 1883, EMQX Dashboard 18083, Redis 6379, MinIO 9000/`9001`, Grafana 3000, and NGINX 80.

Restrict inbound ports through the EC2 security group and host firewall so only required trusted networks can reach them. Do not expose database, Redis, broker, or administrative interfaces publicly without appropriate network controls and authentication.

The Compose file currently sets Grafana's admin password to a literal value. Replace that with a strong secret supplied through environment configuration before production use. Also verify that EMQX has an authenticated user matching the Telegraf MQTT credentials and that the Telegraf output configuration uses the intended credentials.
Troubleshooting
# Service state
docker compose ps

# Logs
docker compose logs --tail=100 timescaledb
docker compose logs --tail=100 emqx
docker compose logs --tail=100 telegraf_server

# Compose validation
docker compose config --quiet

# Disk usage
df -h
sudo du -sh /var/lib/lab-platform/data /var/lib/lab-platform/backups
Do not remove named volumes, bind-mounted data directories, or the TimescaleDB data directory as a generic troubleshooting step. Back up and understand the impact before making destructive changes.
Future roadmap
Phase 1B may add application services such as FastAPI, React, and Celery, plus updated NGINX routing. Add those services to Compose with explicit health checks, secrets/configuration, persistent-storage requirements, and restart policies as appropriate.
