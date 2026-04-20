#!/usr/bin/env bash
# File: plugins/db-seeder/adapters/mysql.sh
#
# Description: MySQL / MariaDB seed adapter.
#              Uses the mysql CLI running inside the dev-mysql container.
#              Supports single .sql files and directories of .sql files (run in sort order).
#
# MIT License
# Copyright (c) [2026] [Topher Frey]

########################################
# ADAPTER CONFIGURATION
########################################

MYSQL_CONTAINER="${MYSQL_CONTAINER:-dev-mysql}"
MYSQL_DEFAULT_DB="${MYSQL_DEFAULT_DB:-dev}"
MYSQL_USER="${MYSQL_USER:-root}"

# Password is read from a container environment variable to avoid
# passing it on the command line (which would expose it in ps output).
# The mysql client reads MYSQL_PWD automatically if set in the environment.
MYSQL_PASSWORD_ENV="${MYSQL_PASSWORD_ENV:-MYSQL_ROOT_PASSWORD}"

########################################
# HELPERS
########################################

_mysql_container_running() {
  docker ps --format '{{.Names}}' | grep -q "^${MYSQL_CONTAINER}$"
}

_mysql_run_file() {
  local FILE="$1"
  local DB="$2"
  local RESET="$3"

  local FILENAME
  FILENAME=$(basename "$FILE")
  local CONTAINER_TMP="/tmp/db-seeder-$FILENAME"

  echo "  → running: $FILENAME against $DB"

  docker cp "$FILE" "${MYSQL_CONTAINER}:${CONTAINER_TMP}"

  if [[ "$RESET" = true && "${_MYSQL_RESET_DONE:-false}" = false ]]; then
    echo "  Dropping and recreating database: $DB"

    docker exec "$MYSQL_CONTAINER" bash -c \
      "MYSQL_PWD=\${$MYSQL_PASSWORD_ENV} mysql -u $MYSQL_USER -e \"DROP DATABASE IF EXISTS \\\`$DB\\\`; CREATE DATABASE \\\`$DB\\\`;\"" 

    _MYSQL_RESET_DONE=true
  fi

  if docker exec "$MYSQL_CONTAINER" bash -c \
      "MYSQL_PWD=\${$MYSQL_PASSWORD_ENV} mysql -u $MYSQL_USER $DB < $CONTAINER_TMP"; then
    green "  ✔ "; echo "$FILENAME applied"
  else
    red "  ✗ Failed to apply $FILENAME"
    docker exec "$MYSQL_CONTAINER" rm -f "$CONTAINER_TMP" 2>/dev/null || true
    exit 1
  fi

  docker exec "$MYSQL_CONTAINER" rm -f "$CONTAINER_TMP" 2>/dev/null || true
}

########################################
# ADAPTER INTERFACE
########################################

adapter_run() {
  local SEED_FILE="$1"
  local DB_NAME="${2:-$MYSQL_DEFAULT_DB}"
  local COLLECTION="${3:-}"    # unused — accepted for interface compatibility
  local RESET="${4:-false}"

  _MYSQL_RESET_DONE=false

  if ! _mysql_container_running; then
    red "MySQL container '$MYSQL_CONTAINER' is not running."
    echo ""
    echo "Start the environment first:"
    echo "  dev-domain up"
    exit 1
  fi

  if ! docker exec "$MYSQL_CONTAINER" which mysql >/dev/null 2>&1; then
    red "mysql client not found in container '$MYSQL_CONTAINER'."
    exit 1
  fi

  if [[ -d "$SEED_FILE" ]]; then

    echo "Seeding all SQL files in: $SEED_FILE"
    echo ""

    local FOUND=false
    while IFS= read -r -d '' f; do
      FOUND=true
      _mysql_run_file "$f" "$DB_NAME" "$RESET"
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

    _mysql_run_file "$SEED_FILE" "$DB_NAME" "$RESET"

  fi

  echo ""
  green "✔ "; echo "MySQL seeding complete (db: $DB_NAME)"
}
