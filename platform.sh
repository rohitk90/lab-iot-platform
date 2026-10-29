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

  local schema_ok
  schema_ok="$(
    docker compose exec -T timescaledb sh -lc \
      'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atqc \
      "SELECT to_regclass('\''platform_data.telemetry'\'') IS NOT NULL;"'
  )"

  if [[ "$schema_ok" != "t" ]]; then
    echo "ERROR: platform_data.telemetry was not found." >&2
    echo "Inspect database initialization logs and existing database state." >&2
    docker compose logs --tail=100 timescaledb
    exit 1
  fi

  echo "Database readiness and telemetry table check passed."
  docker compose ps
}

status() {
  docker compose ps
  echo
  docker compose logs --tail=30 timescaledb
}

backup() {
  check_files
  sudo ./scripts/backup.sh
}

case "${1:-}" in
  setup)  setup ;;
  deploy) deploy ;;
  status) status ;;
  backup) backup ;;
  *) usage; exit 2 ;;
esac
