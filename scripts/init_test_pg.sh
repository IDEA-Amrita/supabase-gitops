#!/usr/bin/env bash
# ==============================================================================
# scripts/init_test_pg.sh
# Starts an isolated postgres:17-alpine Docker container, polls until ready,
# and scaffolds standard Supabase schemas and roles for CI/CD test execution.
#
# Usage:
#   ./scripts/init_test_pg.sh <container_name> [host_port]
# ==============================================================================
set -euo pipefail

CONTAINER_NAME="${1:-pg-test-target}"
HOST_PORT="${2:-5432}"

echo "Starting isolated test container '$CONTAINER_NAME' on port $HOST_PORT..."
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run --name "$CONTAINER_NAME" \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  -p "${HOST_PORT}:5432" \
  -d postgres:17-alpine

echo "Waiting for PostgreSQL engine in '$CONTAINER_NAME' to accept connections..."
until docker exec "$CONTAINER_NAME" pg_isready -U postgres >/dev/null 2>&1 && \
      docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1; do
  sleep 1
done

echo "Scaffolding standard Supabase roles and schemas..."
for i in {1..10}; do
  if docker exec -i "$CONTAINER_NAME" psql -U postgres -d postgres << 'EOF'
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
-- Grant bypassrls to service_role to match Supabase production semantics
ALTER ROLE service_role BYPASSRLS;
ALTER ROLE supabase_admin BYPASSRLS;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE SCHEMA IF NOT EXISTS storage;
CREATE SCHEMA IF NOT EXISTS graphql;

-- Standard mock auth helper
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid AS $$
  SELECT COALESCE(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid;
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION auth.role() RETURNS text AS $$
  SELECT COALESCE(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'),
    current_user
  );
$$ LANGUAGE sql STABLE;
EOF
  then
    break
  fi
  sleep 1
done

echo "Isolated PostgreSQL test container '$CONTAINER_NAME' is ready."
