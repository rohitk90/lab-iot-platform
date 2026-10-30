#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'USAGE'
Usage: ./platform.sh {setup|deploy|status|backup}

  setup   Prepare persistent host directories (run before first deployment)
  deploy  Validate Compose, start services, and check database schema
  status  Show container status and recent TimescaleDB logs
  backup  Run the configured backup script
USAGE
}

check_files() {
  local file
  for file in .env docker-compose.yml infra/timescaledb/init.sql \
              scripts/bootstrap-storage.sh scripts/backup.sh; do
    if [[ ! -f "$file" ]]; then
      echo "ERROR: Required file missing: $file" >&2
      exit 1
    fi
  done
}

setup() {
  check_files
  chmod +x scripts/bootstrap-storage.sh scripts/backup.sh
  sudo ./scripts/bootstrap-storage.sh
  echo "Storage setup complete. Next run: ./platform.sh deploy"
}

deploy() {
  check_files
  docker compose config --quiet

  echo "Starting services..."
  docker compose up -d

  echo "Waiting for TimescaleDB readiness..."
  local ready=false
  for _ in $(seq 1 60); do
    if docker compose exec -T timescaledb sh -lc \
      'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
      >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 2
  done

  if [[ "$ready" != true ]]; then
    echo "ERROR: TimescaleDB did not become ready within 120 seconds." >&2
    docker compose logs --tail=80 timescaledb
    exit 1
  fi

  # V2.3 Schema Check: Verify the core tables AND the archive tables exist.
  # This ensures the whole init.sql transaction committed successfully.
  echo "Verifying V2.3 schema..."
  local schema_ok
  schema_ok="$(
    docker compose exec -T timescaledb sh -lc \
      'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc \
      "SELECT COUNT(*) FROM information_schema.tables 
       WHERE table_schema = '\''platform_data'\'' 
       AND table_name IN ('\''telemetry'\'', '\''telemetry_archive_manifest'\'', '\''telemetry_retention_config'\'');"'
  )"

  if [[ "$schema_ok" != "3" ]]; then
    echo "ERROR: V2.3 schema verification failed." >&2
    echo "Expected 3 core tables, found: $schema_ok" >&2
    echo "Inspect database initialization logs." >&2
    docker compose logs --tail=100 timescaledb
    exit 1
  fi

  echo "Database readiness and V2.3 schema check passed."
  docker compose ps
}

status() {
  docker compose ps
  echo
  docker compose logs --tail=30 timescaledb
}

backup() {
  check_files
  # Run WITHOUT sudo so the resulting backup files are owned by the current
  # user, allowing the 7-day retention cleanup to succeed on future runs.
  ./scripts/backup.sh
}

case "${1:-}" in
  setup)  setup ;;
  deploy) deploy ;;
  status) status ;;
  backup) backup ;;
  *) usage; exit 2 ;;
esac
