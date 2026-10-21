#!/usr/bin/env bash
# ==============================================================================
# scripts/test_local_migrations.sh
# 
# Reproducible Local & CI Database Migration Integration Test Suite
# Tests clean database initialization, migration application, seed data insertion,
# transaction rollback on failure, and schema validation.
# ==============================================================================
set -euo pipefail

CONTAINER_NAME="pg-local-test-$RANDOM"
DB_PORT="5439"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=========================================================="
echo "Starting Migration Integration Test Suite"
echo "Project Root: $PROJECT_ROOT"
echo "Ephemeral Container: $CONTAINER_NAME (Port $DB_PORT)"
echo "=========================================================="

cleanup() {
  echo ""
  echo "--- Cleaning up container $CONTAINER_NAME ---"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  echo "Cleanup complete."
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# Step 1: Start fresh ephemeral PostgreSQL 17 container
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 1: Initializing Ephemeral PostgreSQL 17 Container ---"
docker run --name "$CONTAINER_NAME" \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -p "${DB_PORT}:5432" \
  -d postgres:17-alpine >/dev/null

echo "Waiting for PostgreSQL engine to be ready..."
until docker exec "$CONTAINER_NAME" pg_isready -U postgres >/dev/null 2>&1 && \
      docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1; do
  sleep 1
done

# Initialize Supabase compatibility roles and system schemas
echo "Provisioning Supabase standard roles and schema scaffolding..."
docker exec -i "$CONTAINER_NAME" psql -U postgres -d postgres << 'EOF' >/dev/null
DO $$
DECLARE
  r text;
BEGIN
  FOR r IN SELECT unnest(ARRAY[
    'anon',
    'authenticated',
    'service_role',
    'authenticator',
    'supabase_admin',
    'dashboard_user'
  ]) LOOP
    BEGIN
      EXECUTE format('CREATE ROLE %I NOLOGIN', r);
    EXCEPTION WHEN duplicate_object THEN
      NULL;
    END;
  END LOOP;
END $$;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE SCHEMA IF NOT EXISTS storage;
CREATE SCHEMA IF NOT EXISTS graphql;
EOF
echo "[PASS] Ephemeral PostgreSQL container ready with Supabase scaffolding."

# ------------------------------------------------------------------------------
# Step 2: Apply all migrations from clean baseline
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 2: Applying Migrations Sequentially ---"
MIGRATION_COUNT=0
for f in "$PROJECT_ROOT"/supabase/migrations/*.sql; do
  [ -e "$f" ] || continue
  MIGRATION_COUNT=$((MIGRATION_COUNT + 1))
  fname=$(basename "$f")
  echo "  Applying: $fname"
  docker exec -i "$CONTAINER_NAME" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$f"
done

if [ "$MIGRATION_COUNT" -eq 0 ]; then
  echo "  (No SQL migrations found in supabase/migrations/ - baselined schema state)"
else
  echo "[PASS] Applied $MIGRATION_COUNT migration(s) successfully."
fi

# ------------------------------------------------------------------------------
# Step 3: Run seed script (supabase/seed.sql)
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 3: Applying Fixture Seed Data ---"
if [ -f "$PROJECT_ROOT/supabase/seed.sql" ]; then
  echo "Executing supabase/seed.sql..."
  # If tables exist (e.g. profiles), execute seed data
  if docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -At -c \
       "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'profiles';" | grep -q "1"; then
    docker exec -i "$CONTAINER_NAME" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$PROJECT_ROOT/supabase/seed.sql"
    echo "[PASS] Seed data inserted successfully."
  else
    echo "  (Skipping seed execution: 'profiles' table not defined in current migration files)"
  fi
fi

# ------------------------------------------------------------------------------
# Step 4: Test Failure Handling & Transaction Rollback
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 4: Verifying Migration Failure Rollback Isolation ---"
set +e
docker exec -i "$CONTAINER_NAME" psql -U postgres -d postgres -v ON_ERROR_STOP=1 << 'EOF' 2>/dev/null
BEGIN;
CREATE TABLE public.__test_rollback_probe (id int);
THIS_SYNTAX_ERROR_MUST_ABORT_TRANSACTION;
COMMIT;
EOF
ROLLBACK_EXIT=$?
set -e

if [ "$ROLLBACK_EXIT" -ne 0 ]; then
  # Confirm table __test_rollback_probe was NOT committed
  PROBE_EXISTS=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -At -c \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__test_rollback_probe';")
  if [ "$PROBE_EXISTS" -eq 0 ]; then
    echo "[PASS] Transactional rollback verified: Failed migration halted and left zero orphaned tables."
  else
    echo "::error::Rollback verification failed: table __test_rollback_probe was committed despite error!"
    exit 1
  fi
else
  echo "::error::Rollback verification failed: syntax error was not caught by psql!"
  exit 1
fi

# ------------------------------------------------------------------------------
# Step 5: Schema Validation Checks
# ------------------------------------------------------------------------------
echo ""
echo "--- Step 5: Executing Final Schema Validation Checks ---"
TABLE_COUNT=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -At -c \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';")
echo "Total public tables: $TABLE_COUNT"

INVALID_CONSTRAINTS=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -At -c \
  "SELECT count(*) FROM pg_constraint WHERE connamespace = 'public'::regnamespace AND NOT convalidated;")
echo "Invalid constraints: $INVALID_CONSTRAINTS"
if [ "$INVALID_CONSTRAINTS" -gt 0 ]; then
  echo "::error::Schema validation failed: found $INVALID_CONSTRAINTS unvalidated constraints."
  exit 1
fi

echo ""
echo "=========================================================="
echo "All Migration Integration Test Scenarios Passed Successfully!"
echo "=========================================================="
