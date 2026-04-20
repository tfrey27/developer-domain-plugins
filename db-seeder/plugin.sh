#!/usr/bin/env bash
# File: plugins/db-seeder/plugin.sh
#
# Description: Main entrypoint for the db-seeder plugin.
#              Routes subcommands and handles database auto-detection.
#
# MIT License
# Copyright (c) [2026] [Topher Frey]

set -e

########################################
# PATHS
########################################

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTERS_DIR="$PLUGIN_DIR/adapters"

# Seeds live in the project root under seeds/<adapter>/
# e.g. seeds/mongo/users.json  seeds/postgres/schema.sql
SEEDS_DIR="$DEV_DOMAIN_ROOT/seeds"

########################################
# COLOR HELPERS (mirrors utils.sh)
########################################

green()  { printf "\033[1;32m%s\033[0m" "$1"; }
red()    { printf "\033[1;31m%s\033[0m" "$1"; }
yellow() { echo -e "\033[1;33m$1\033[0m"; }
blue()   { echo -e "\033[1;34m$1\033[0m"; }

########################################
# KNOWN DATABASE SERVICES
# Maps service name → adapter name.
# Add new entries here as adapters are added.
########################################

# Bash 3.2 compatible — parallel arrays instead of associative array
DB_SERVICE_NAMES=( "mongo"  "mongodb"  "postgres"  "postgresql"  "mysql"  "mariadb" )
DB_ADAPTER_NAMES=( "mongo"  "mongo"    "postgres"  "postgres"    "mysql"  "mysql"   )

_service_to_adapter() {
  local SERVICE="$1"
  local i=0
  for name in "${DB_SERVICE_NAMES[@]}"; do
    if [[ "$name" == "$SERVICE" ]]; then
      echo "${DB_ADAPTER_NAMES[$i]}"
      return 0
    fi
    (( i++ )) || true
  done
  return 1
}

########################################
# AUTO-DETECT DATABASE
# Reads DEV_DOMAIN_SERVICES (injected by plugins.sh _export_plugin_env).
# Returns the adapter name if exactly one DB service is enabled.
########################################

_detect_db() {
  local MATCHED_SERVICES=()
  local MATCHED_ADAPTERS=()

  for svc in $DEV_DOMAIN_SERVICES; do
    local adapter
    if adapter=$(_service_to_adapter "$svc" 2>/dev/null); then
      MATCHED_SERVICES+=("$svc")
      MATCHED_ADAPTERS+=("$adapter")
    fi
  done

  local count=${#MATCHED_SERVICES[@]}

  if [[ $count -eq 0 ]]; then
    red "No database services are currently enabled."
    echo ""
    echo "Enable a database service first:"
    echo "  dev-domain add-service mongo"
    echo "  dev-domain add-service postgres"
    exit 1
  fi

  if [[ $count -gt 1 ]]; then
    red "Multiple database services are enabled. Please specify which to seed:"
    echo ""
    for svc in "${MATCHED_SERVICES[@]}"; do
      echo "  dev-domain db-seeder run $svc --file <path>"
    done
    exit 1
  fi

  echo "${MATCHED_ADAPTERS[0]}"
}

########################################
# LOAD ADAPTER
########################################

_load_adapter() {
  local ADAPTER="$1"
  local ADAPTER_FILE="$ADAPTERS_DIR/$ADAPTER.sh"

  if [[ ! -f "$ADAPTER_FILE" ]]; then
    red "Unsupported database adapter: '$ADAPTER'"
    echo ""
    echo "Available adapters:"
    for f in "$ADAPTERS_DIR"/*.sh; do
      echo "  - $(basename "$f" .sh)"
    done
    exit 1
  fi

  # shellcheck source=/dev/null
  source "$ADAPTER_FILE"
}

########################################
# SUBCOMMANDS
########################################

# dev-domain db-seeder run [<service>] --file <path> [--db <dbname>] [--collection <name>] [--reset]
_cmd_run() {

  local TARGET_SERVICE=""
  local SEED_FILE=""
  local DB_NAME=""
  local COLLECTION=""
  local RESET=false

  # First positional arg (if not a flag) is the explicit service name
  if [[ -n "$1" && "$1" != --* ]]; then
    TARGET_SERVICE="$1"
    shift
  fi

  # Parse remaining flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)
        SEED_FILE="$2"
        shift 2
        ;;
      --db)
        DB_NAME="$2"
        shift 2
        ;;
      --collection)
        COLLECTION="$2"
        shift 2
        ;;
      --reset)
        RESET=true
        shift
        ;;
      *)
        red "Unknown flag: $1"
        echo "Run 'dev-domainer help' for usage."
        exit 1
        ;;
    esac
  done

  if [[ -z "$SEED_FILE" ]]; then
    red "A seed file is required."
    echo ""
    echo "Usage:"
    echo "  dev-domain db-seeder run [<service>] --file <path>"
    exit 1
  fi

  # Resolve relative paths against project root
  if [[ "$SEED_FILE" != /* ]]; then
    SEED_FILE="$DEV_DOMAIN_ROOT/$SEED_FILE"
  fi

  if [[ ! -f "$SEED_FILE" && ! -d "$SEED_FILE" ]]; then
    red "Seed file not found: $SEED_FILE"
    exit 1
  fi

  # Resolve adapter — auto-detect if no service specified
  local ADAPTER
  if [[ -n "$TARGET_SERVICE" ]]; then
    if ! ADAPTER=$(_service_to_adapter "$TARGET_SERVICE"); then
      red "Unknown database service: '$TARGET_SERVICE'"
      echo ""
      echo "Supported services: ${DB_SERVICE_NAMES[*]}"
      exit 1
    fi
  else
    ADAPTER=$(_detect_db)
  fi

  _load_adapter "$ADAPTER"

  echo ""
  blue "db-seeder › $ADAPTER"
  echo "--------------------------------"
  echo " seed file : $SEED_FILE"
  [[ -n "$DB_NAME"    ]] && echo " database  : $DB_NAME"
  [[ -n "$COLLECTION" ]] && echo " collection: $COLLECTION"
  [[ "$RESET" = true  ]] && echo " mode      : reset + reseed"
  echo ""

  adapter_run "$SEED_FILE" "$DB_NAME" "$COLLECTION" "$RESET"
}

# dev-domain db-seeder list [<service>]
_cmd_list() {
  local TARGET_SERVICE="${1:-}"

  echo ""
  blue "Available Seed Files"
  echo "--------------------------------"

  if [[ ! -d "$SEEDS_DIR" ]]; then
    yellow "No seeds directory found at: $SEEDS_DIR"
    echo ""
    echo "Create seed files under:"
    echo "  seeds/mongo/      → .json, .bson"
    echo "  seeds/postgres/   → .sql"
    echo "  seeds/mysql/      → .sql"
    echo ""
    return
  fi

  local FOUND=false

  for dir in "$SEEDS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local adapter_name
    adapter_name=$(basename "$dir")

    # Filter by service if specified
    if [[ -n "$TARGET_SERVICE" ]]; then
      local expected_adapter
      if ! expected_adapter=$(_service_to_adapter "$TARGET_SERVICE" 2>/dev/null); then
        expected_adapter="$TARGET_SERVICE"
      fi
      [[ "$adapter_name" != "$expected_adapter" ]] && continue
    fi

    echo " [$adapter_name]"

    shopt -s nullglob
    local files=("$dir"*)
    shopt -u nullglob

    if [[ ${#files[@]} -eq 0 ]]; then
      echo "   (no seed files)"
    else
      for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        echo "   - $(basename "$f")"
        FOUND=true
      done
    fi

    echo ""
  done

  if [[ "$FOUND" = false && -z "$TARGET_SERVICE" ]]; then
    echo " (no seed files found)"
    echo ""
  fi
}

# dev-domain db-seeder init
# Scaffolds the seeds directory structure
_cmd_init() {
  echo ""
  blue "Initializing seeds directory..."
  echo ""

  mkdir -p "$SEEDS_DIR/mongo"
  mkdir -p "$SEEDS_DIR/postgres"
  mkdir -p "$SEEDS_DIR/mysql"

  # Write example files only if they don't already exist
  local MONGO_EXAMPLE="$SEEDS_DIR/mongo/example.json"
  if [[ ! -f "$MONGO_EXAMPLE" ]]; then
    cat > "$MONGO_EXAMPLE" <<'EOF'
[
  { "name": "Alice", "email": "alice@example.com", "role": "admin" },
  { "name": "Bob",   "email": "bob@example.com",   "role": "user"  }
]
EOF
    echo " created: seeds/mongo/example.json"
  fi

  local PG_EXAMPLE="$SEEDS_DIR/postgres/example.sql"
  if [[ ! -f "$PG_EXAMPLE" ]]; then
    cat > "$PG_EXAMPLE" <<'EOF'
-- Example PostgreSQL seed
CREATE TABLE IF NOT EXISTS users (
  id    SERIAL PRIMARY KEY,
  name  TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  role  TEXT NOT NULL DEFAULT 'user'
);

INSERT INTO users (name, email, role) VALUES
  ('Alice', 'alice@example.com', 'admin'),
  ('Bob',   'bob@example.com',   'user')
ON CONFLICT (email) DO NOTHING;
EOF
    echo " created: seeds/postgres/example.sql"
  fi

  local MYSQL_EXAMPLE="$SEEDS_DIR/mysql/example.sql"
  if [[ ! -f "$MYSQL_EXAMPLE" ]]; then
    cat > "$MYSQL_EXAMPLE" <<'EOF'
-- Example MySQL seed
CREATE TABLE IF NOT EXISTS users (
  id    INT AUTO_INCREMENT PRIMARY KEY,
  name  VARCHAR(255) NOT NULL,
  email VARCHAR(255) NOT NULL UNIQUE,
  role  VARCHAR(50)  NOT NULL DEFAULT 'user'
);

INSERT IGNORE INTO users (name, email, role) VALUES
  ('Alice', 'alice@example.com', 'admin'),
  ('Bob',   'bob@example.com',   'user');
EOF
    echo " created: seeds/mysql/example.sql"
  fi

  echo ""
  green "✔ "; echo "Seeds directory ready at: seeds/"
  echo ""
  echo "Run seed files with:"
  echo "  dev-domain db-seeder run --file seeds/mongo/example.json"
  echo "  dev-domain db-seeder run postgres --file seeds/postgres/example.sql"
  echo ""
}

# dev-domain db-seeder help
_cmd_help() {
  echo ""
  blue "db-seeder — Database Seeding Plugin"
  echo "------------------------------------------------"
  echo ""
  echo "Commands:"
  echo ""
  echo "  run [<service>] --file <path> [options]"
  echo "    Seed a database from a file."
  echo "    <service> is optional when exactly one database is enabled."
  echo ""
  echo "    Options:"
  echo "      --file <path>         Path to seed file or directory (required)"
  echo "      --db <name>           Target database name (optional, adapter default used if omitted)"
  echo "      --collection <name>   Target collection/table (mongo only, optional)"
  echo "      --reset               Drop and recreate before seeding"
  echo ""
  echo "  list [<service>]"
  echo "    List available seed files."
  echo ""
  echo "  init"
  echo "    Scaffold the seeds/ directory with example files."
  echo ""
  echo "  help"
  echo "    Show this help message."
  echo ""
  echo "Supported services:"
  echo "  mongo, mongodb   → JSON / BSON via mongoimport"
  echo "  postgres         → SQL via psql"
  echo "  mysql, mariadb   → SQL via mysql client"
  echo ""
  echo "Seed file conventions:"
  echo "  seeds/mongo/        → .json files (array of documents)"
  echo "  seeds/postgres/     → .sql files"
  echo "  seeds/mysql/        → .sql files"
  echo ""
  echo "Examples:"
  echo "  dev-domain db-seeder run --file seeds/mongo/users.json"
  echo "  dev-domain db-seeder run postgres --file seeds/postgres/schema.sql --db myapp"
  echo "  dev-domain db-seeder run mongo --file seeds/mongo/users.json --collection users --reset"
  echo "  dev-domain db-seeder list"
  echo "  dev-domain db-seeder init"
  echo ""
}

########################################
# ROUTER
########################################

SUBCOMMAND="${1:-help}"
shift || true

case "$SUBCOMMAND" in
  run)
    _cmd_run "$@"
    ;;
  list)
    _cmd_list "$@"
    ;;
  init)
    _cmd_init
    ;;
  help|--help|-h)
    _cmd_help
    ;;
  *)
    red "Unknown subcommand: '$SUBCOMMAND'"
    echo ""
    _cmd_help
    exit 1
    ;;
esac
