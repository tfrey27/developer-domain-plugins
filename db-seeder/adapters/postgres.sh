#!/usr/bin/env bash
# File: plugins/db-seeder/adapters/postgres.sh
#
# Description: PostgreSQL seed adapter.
#              Uses psql running inside the dev-postgres container.
#              Supports single .sql files and directories of .sql files (run in sort order).
#
# MIT License
# Copyright (c) [2026] [Topher Frey]

########################################
# ADAPTER CONFIGURATION
########################################

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-dev-postgres}"
POSTGRES_DEFAULT_DB="${POSTGRES_DEFAULT_DB:-dev}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"

########################################
# HELPERS
########################################

_postgres_container_running() {
  docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"
}

_postgres_run_file() {
  local FILE="$1"
  local DB="$2"
  local RESET="$3"

  local FILENAME
  FILENAME=$(basename "$FILE")
  local CONTAINER_TMP="/tmp/db-seed-$FILENAME"

  echo "  → running: $FILENAME against $DB"

  # Copy seed file into container
  docker cp "$FILE" "${POSTGRES_CONTAINER}:${CONTAINER_TMP}"

  if [[ "$RESET" = true ]]; then

    # Drop and recreate the target database before running the file
    # Only runs once — tracked by a flag so a directory of files
    # doesn't drop on every iteration
    if [[ "${_PG_RESET_DONE:-false}" = false ]]; then
      echo "  Dropping and recreating database: $DB"

      docker exec "$POSTGRES_CONTAINER" psql \
        -U "$POSTGRES_USER" \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid <> pg_backend_pid();" \
        postgres >/dev/null 2>&1 || true

      docker exec "$POSTGRES_CONTAINER" psql \
        -U "$POSTGRES_USER" \
        -c "DROP DATABASE IF EXISTS \"$DB\";" \
        postgres

      docker exec "$POSTGRES_CONTAINER" psql \
        -U "$POSTGRES_USER" \
        -c "CREATE DATABASE \"$DB\";" \
        postgres

      _PG_RESET_DONE=true
    fi
  fi

  # Run the SQL file
  if docker exec "$POSTGRES_CONTAINER" psql \
      -U "$POSTGRES_USER" \
      -d "$DB" \
      -f "$CONTAINER_TMP"; then
    green "  ✔ "; echo "$FILENAME applied"
  else
    red "  ✗ Failed to apply $FILENAME"
    docker exec "$POSTGRES_CONTAINER" rm -f "$CONTAINER_TMP" 2>/dev/null || true
    exit 1
  fi

  docker exec "$POSTGRES_CONTAINER" rm -f "$CONTAINER_TMP" 2>/dev/null || true
}

########################################
# ADAPTER INTERFACE
########################################

adapter_run() {
  local SEED_FILE="$1"
  local DB_NAME="${2:-$POSTGRES_DEFAULT_DB}"
  local COLLECTION="${3:-}"    # unused for postgres — accepted for interface compatibility
  local RESET="${4:-false}"

  _PG_RESET_DONE=false

  if ! _postgres_container_running; then
    red "PostgreSQL container '$POSTGRES_CONTAINER' is not running."
    echo ""
    echo "Start the environment first:"
    echo "  dev-domain up"
    exit 1
  fi

  if ! docker exec "$POSTGRES_CONTAINER" which psql >/dev/null 2>&1; then
    red "psql not found in container '$POSTGRES_CONTAINER'."
    exit 1
  fi

  if [[ -d "$SEED_FILE" ]]; then

    echo "Seeding all SQL files in: $SEED_FILE"
    echo ""

    # Sort files so they run in predictable order (01_schema.sql before 02_data.sql)
    local FOUND=false
    while IFS= read -r -d '' f; do
      FOUND=true
      _postgres_run_file "$f" "$DB_NAME" "$RESET"
      echo ""
    done < <(find "$SEED_FILE" -maxdepth 1 -name "*.sql" -print0 | sort -z)

    if [[ "$FOUND" = false ]]; then
      yellow "No .sql files found in: $SEED_FILE"
    fi

  else

    local EXT="${SEED_FILE##*.}"
    if [[ "$EXT" != "sql" ]]; then
      yellow "Warning: expected a .sql file, got .$EXT"
    fi

    _postgres_run_file "$SEED_FILE" "$DB_NAME" "$RESET"

  fi

  echo ""
  green "✔ "; echo "PostgreSQL seeding complete (db: $DB_NAME)"
}
