#!/usr/bin/env bash
# File: plugins/db-seeder/adapters/mongo.sh
#
# Description: MongoDB seed adapter.
#              Uses mongoimport running inside the dev-mongo container.
#              Supports JSON files and directories of JSON files.
#
# MIT License
# Copyright (c) [2026] [Topher Frey]

########################################
# ADAPTER CONFIGURATION
########################################

# The container name to exec into.
# Follows the dev- prefix convention used by dev-domain services.
MONGO_CONTAINER="${MONGO_CONTAINER:-dev-mongo}"

# Default database to seed into if --db is not provided.
MONGO_DEFAULT_DB="${MONGO_DEFAULT_DB:-dev}"

########################################
# HELPERS
########################################

_mongo_container_running() {
  docker ps --format '{{.Names}}' | grep -q "^${MONGO_CONTAINER}$"
}

_mongo_copy_and_import() {
  local FILE="$1"
  local DB="$2"
  local COLLECTION="$3"
  local RESET="$4"

  local FILENAME
  FILENAME=$(basename "$FILE")

  # Derive collection name from filename if not specified
  if [[ -z "$COLLECTION" ]]; then
    COLLECTION="${FILENAME%.*}"
  fi

  local CONTAINER_TMP="/tmp/db-seeder-$FILENAME"

  echo "  → importing: $FILENAME into $DB.$COLLECTION"

  # Copy seed file into container
  docker cp "$FILE" "${MONGO_CONTAINER}:${CONTAINER_TMP}"

  # Build mongoimport flags
  local FLAGS="--db=$DB --collection=$COLLECTION --file=$CONTAINER_TMP --jsonArray"

  if [[ "$RESET" = true ]]; then
    FLAGS="$FLAGS --drop"
  else
    FLAGS="$FLAGS --mode=upsert"
  fi

  # Run mongoimport inside container
  if docker exec "$MONGO_CONTAINER" mongoimport $FLAGS; then
    green "  ✔ "; echo "$COLLECTION seeded"
  else
    red "  ✗ Failed to seed $COLLECTION"
    docker exec "$MONGO_CONTAINER" rm -f "$CONTAINER_TMP" 2>/dev/null || true
    exit 1
  fi

  # Cleanup temp file
  docker exec "$MONGO_CONTAINER" rm -f "$CONTAINER_TMP" 2>/dev/null || true
}

########################################
# ADAPTER INTERFACE
# Called by plugin.sh as: adapter_run <file> <db> <collection> <reset>
########################################

adapter_run() {
  local SEED_FILE="$1"
  local DB_NAME="${2:-$MONGO_DEFAULT_DB}"
  local COLLECTION="${3:-}"
  local RESET="${4:-false}"

  # Verify container is running
  if ! _mongo_container_running; then
    red "MongoDB container '$MONGO_CONTAINER' is not running."
    echo ""
    echo "Start the environment first:"
    echo "  dev-domain up"
    exit 1
  fi

  # Verify mongoimport is available in the container
  if ! docker exec "$MONGO_CONTAINER" which mongoimport >/dev/null 2>&1; then
    red "mongoimport not found in container '$MONGO_CONTAINER'."
    echo "The mongo image must include MongoDB Database Tools."
    exit 1
  fi

  if [[ -d "$SEED_FILE" ]]; then

    # Directory mode — import every .json file in the directory
    echo "Seeding all JSON files in: $SEED_FILE"
    echo ""

    local FOUND=false
    shopt -s nullglob
    for f in "$SEED_FILE"/*.json; do
      FOUND=true
      _mongo_copy_and_import "$f" "$DB_NAME" "" "$RESET"
      echo ""
    done
    shopt -u nullglob

    if [[ "$FOUND" = false ]]; then
      yellow "No .json files found in: $SEED_FILE"
    fi

  else

    # Single file mode
    local EXT="${SEED_FILE##*.}"
    if [[ "$EXT" != "json" && "$EXT" != "bson" ]]; then
      yellow "Warning: expected .json or .bson file, got .$EXT"
    fi

    _mongo_copy_and_import "$SEED_FILE" "$DB_NAME" "$COLLECTION" "$RESET"

  fi

  echo ""
  green "✔ "; echo "MongoDB seeding complete (db: $DB_NAME)"
}
