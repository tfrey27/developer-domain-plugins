# db-seeder

A dev-domain plugin for seeding databases from local files.

Supports **MongoDB**, **PostgreSQL**, and **MySQL / MariaDB** via each database's native CLI tooling running inside the service container. No additional drivers or runtimes required on the host.

---

## Installation

```bash
dev-domain plugin install db-seeder
```

---

## Seed File Conventions

Seed files live in a `seeds/` directory at the project root, organized by adapter:

```
seeds/
├── mongo/
│   ├── users.json
│   └── products.json
├── postgres/
│   ├── 01_schema.sql
│   └── 02_data.sql
└── mysql/
    └── seed.sql
```

Run `dev-domain db-seeder init` to scaffold this structure with example files.

**MongoDB** — JSON files containing an array of documents:
```json
[
  { "name": "Alice", "email": "alice@example.com", "role": "admin" },
  { "name": "Bob",   "email": "bob@example.com",   "role": "user"  }
]
```

**PostgreSQL / MySQL** — standard `.sql` files. Files in a directory are run in alphabetical order, so prefix with numbers to control execution order (`01_schema.sql` before `02_data.sql`).

---

## Commands

### `run`

Seed a database from a file or directory.

```bash
# Auto-detect database (works when exactly one DB service is enabled)
dev-domain db-seeder run --file seeds/mongo/users.json

# Explicit service name (required when multiple DB services are enabled)
dev-domain db-seeder run mongo    --file seeds/mongo/users.json
dev-domain db-seeder run postgres --file seeds/postgres/01_schema.sql
dev-domain db-seeder run mysql    --file seeds/mysql/seed.sql

# Seed an entire directory (all files imported in order)
dev-domain db-seeder run postgres --file seeds/postgres/

# Target a specific database name
dev-domain db-seeder run postgres --file seeds/postgres/data.sql --db myapp

# MongoDB: target a specific collection
dev-domain db-seeder run mongo --file seeds/mongo/users.json --collection users

# Reset (drop + recreate) before seeding
dev-domain db-seeder run postgres --file seeds/postgres/ --reset
```

### `list`

List available seed files.

```bash
dev-domain db-seeder list           # all adapters
dev-domain db-seeder list mongo     # mongo seeds only
dev-domain db-seeder list postgres  # postgres seeds only
```

### `init`

Scaffold the `seeds/` directory with commented example files.

```bash
dev-domain db-seeder init
```

### `help`

```bash
dev-domain db-seeder help
```

---

## Options

| Flag | Description |
|---|---|
| `--file <path>` | Path to seed file or directory **(required)** |
| `--db <name>` | Target database name (defaults: `dev` for all adapters) |
| `--collection <name>` | Target collection — MongoDB only, derived from filename if omitted |
| `--reset` | Drop and recreate the database before seeding |

---

## Adapter Defaults

Defaults can be overridden by setting environment variables before running the command.

### MongoDB

| Variable | Default |
|---|---|
| `MONGO_CONTAINER` | `dev-mongo` |
| `MONGO_DEFAULT_DB` | `dev` |

### PostgreSQL

| Variable | Default |
|---|---|
| `POSTGRES_CONTAINER` | `dev-postgres` |
| `POSTGRES_DEFAULT_DB` | `dev` |
| `POSTGRES_USER` | `postgres` |

### MySQL / MariaDB

| Variable | Default |
|---|---|
| `MYSQL_CONTAINER` | `dev-mysql` |
| `MYSQL_DEFAULT_DB` | `dev` |
| `MYSQL_USER` | `root` |
| `MYSQL_PASSWORD_ENV` | `MYSQL_ROOT_PASSWORD` |

MySQL passwords are read from the container's own environment variable (the value of `MYSQL_PASSWORD_ENV`) rather than passed on the CLI, keeping credentials out of process listings.

---

## How It Works

1. The plugin reads `DEV_DOMAIN_SERVICES` (injected by dev-domain's plugin system) to identify which database services are currently enabled.
2. If exactly one known database service is enabled, it auto-selects the matching adapter. If multiple are enabled, the service name must be provided explicitly.
3. The seed file is copied into the running container via `docker cp`.
4. The adapter runs the appropriate import tool inside the container (`mongoimport`, `psql`, or `mysql`).
5. The temporary file is cleaned up from the container after the import completes.

---

## Adding a New Adapter

Create `adapters/<name>.sh` implementing a single function:

```bash
adapter_run() {
  local SEED_FILE="$1"   # absolute path on host
  local DB_NAME="$2"     # target database (may be empty — use your default)
  local COLLECTION="$3"  # collection/table hint (may be empty)
  local RESET="$4"       # "true" or "false"

  # your implementation
}
```

Then register the service → adapter mapping in `plugin.sh`:

```bash
DB_SERVICE_NAMES=( ... "mynewdb" )
DB_ADAPTER_NAMES=( ... "mynewdb" )
```
