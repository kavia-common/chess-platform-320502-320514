#!/bin/bash

# PostgreSQL startup + chess schema initialization
# This container uses a local Postgres instance (non-docker) listening on DB_PORT.

set -euo pipefail

DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_SQL_FILE="${SCRIPT_DIR}/init_chess_schema.sql"

echo "Starting PostgreSQL setup..."

# Find PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Found PostgreSQL version: ${PG_VERSION}"

is_pg_ready() {
  sudo -u postgres "${PG_BIN}/pg_isready" -p "${DB_PORT}" >/dev/null 2>&1
}

start_postgres_if_needed() {
  if is_pg_ready; then
    echo "PostgreSQL is already running on port ${DB_PORT}."
    return 0
  fi

  # Also check if there's a PostgreSQL process running (in case pg_isready fails)
  if pgrep -f "postgres.*-p ${DB_PORT}" >/dev/null 2>&1; then
    echo "Found existing PostgreSQL process on port ${DB_PORT} but readiness check failed."
    echo "Proceeding without starting a new server."
    return 0
  fi

  # Initialize PostgreSQL data directory if it doesn't exist
  if [ ! -f "/var/lib/postgresql/data/PG_VERSION" ]; then
    echo "Initializing PostgreSQL data directory..."
    sudo -u postgres "${PG_BIN}/initdb" -D /var/lib/postgresql/data
  fi

  # Start PostgreSQL server in background
  echo "Starting PostgreSQL server..."
  sudo -u postgres "${PG_BIN}/postgres" -D /var/lib/postgresql/data -p "${DB_PORT}" &

  # Wait for PostgreSQL to start
  echo "Waiting for PostgreSQL to become ready..."
  for i in {1..15}; do
    if is_pg_ready; then
      echo "PostgreSQL is ready!"
      return 0
    fi
    echo "Waiting... ($i/15)"
    sleep 2
  done

  echo "PostgreSQL did not become ready in time." >&2
  exit 1
}

ensure_db_and_user() {
  echo "Setting up database and user..."

  # Create DB if it doesn't exist (ignore error if it exists)
  sudo -u postgres "${PG_BIN}/createdb" -p "${DB_PORT}" "${DB_NAME}" 2>/dev/null || true

  # Create/update role and grant privileges
  sudo -u postgres "${PG_BIN}/psql" -p "${DB_PORT}" -d postgres << EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;

GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

\\c ${DB_NAME}

GRANT USAGE ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};
GRANT ALL ON SCHEMA public TO ${DB_USER};

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
EOF
}

apply_schema() {
  if [ ! -f "${INIT_SQL_FILE}" ]; then
    echo "Schema file not found: ${INIT_SQL_FILE}" >&2
    exit 1
  fi

  echo "Applying chess platform schema from: ${INIT_SQL_FILE}"
  # Run as postgres for simplest permissions handling; objects will be usable by DB_USER due to grants/default privileges above.
  sudo -u postgres "${PG_BIN}/psql" -p "${DB_PORT}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -f "${INIT_SQL_FILE}"
  echo "Schema initialization complete."
}

write_connection_files() {
  # Connection helper for humans/scripts
  echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > "${SCRIPT_DIR}/db_connection.txt"
  echo "Connection string saved to db_connection.txt"

  # Environment variables for the DB visualizer and other local tools
  cat > "${SCRIPT_DIR}/db_visualizer/postgres.env" << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

  echo "Environment variables saved to db_visualizer/postgres.env"
}

print_summary() {
  echo ""
  echo "PostgreSQL setup complete!"
  echo "Database: ${DB_NAME}"
  echo "User: ${DB_USER}"
  echo "Port: ${DB_PORT}"
  echo ""
  echo "To connect:"
  echo "  psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
  echo "  $(cat "${SCRIPT_DIR}/db_connection.txt")"
}

start_postgres_if_needed
ensure_db_and_user
apply_schema
write_connection_files
print_summary
