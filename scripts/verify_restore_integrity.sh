#!/usr/bin/env bash
# ==============================================================================
# scripts/verify_restore_integrity.sh
# 
# Deep post-restore integrity and health assertion script for Supabase GitOps.
# Validates table inventory, row counts, constraints, index validity, and read viability.
# ==============================================================================
set -euo pipefail

CONTAINER_NAME="${1:-pg-restore-target}"
MIN_TABLES="${2:-1}"

echo "=========================================================="
echo "Starting Deep Post-Restore Database Verification"
echo "Target Container: $CONTAINER_NAME"
echo "Minimum Expected Tables: $MIN_TABLES"
echo "=========================================================="

# 1. Container Isolation & Connectivity Check
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "::error::Target container '${CONTAINER_NAME}' is not running."
  exit 1
fi

PG_VERSION=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -At -c "SELECT version();")
echo "Connected to container: $PG_VERSION"

# 2. Table Inventory Check
echo ""
echo "--- 1. Checking Table Inventory ---"
TABLE_LIST=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -At -c \
  "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name;")

if [ -z "$TABLE_LIST" ]; then
  TABLE_COUNT=0
else
  TABLE_COUNT=$(echo "$TABLE_LIST" | wc -l)
fi

echo "Found $TABLE_COUNT public base table(s):"
while IFS= read -r tbl; do
  [ -z "$tbl" ] && continue
  echo "  - public.$tbl"
done <<< "$TABLE_LIST"

if [ "$TABLE_COUNT" -lt "$MIN_TABLES" ]; then
  echo "::error::Integrity check failed: found $TABLE_COUNT tables, expected at least $MIN_TABLES."
  exit 1
fi

# 3. Table Rows & Data Density
echo ""
echo "--- 2. Checking Table Row Counts & Data Viability ---"
ROW_SUMMARY=""
while IFS= read -r tbl; do
  [ -z "$tbl" ] && continue
  COUNT=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -At -c "SELECT count(*) FROM public.\"$tbl\";")
  echo "  - public.$tbl: $COUNT row(s)"
  if [ -z "$ROW_SUMMARY" ]; then
    ROW_SUMMARY="${tbl}: ${COUNT}"
  else
    ROW_SUMMARY="${ROW_SUMMARY}
${tbl}: ${COUNT}"
  fi
done <<< "$TABLE_LIST"

# 4. Constraint & Foreign Key Validation
echo ""
echo "--- 3. Checking Constraints & Referential Integrity ---"
CONSTRAINTS_RAW=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -At -F'|' -c \
  "SELECT conname, contype, conrelid::regclass::text, coalesce(confrelid::regclass::text, '-'), convalidated 
   FROM pg_constraint 
   WHERE connamespace = 'public'::regnamespace 
   ORDER BY contype, conname;")

TOTAL_CONSTRAINTS=0
PK_COUNT=0
FK_COUNT=0
INVALID_CONSTRAINTS=0
CONSTRAINT_DETAILS=""

if [ -n "$CONSTRAINTS_RAW" ]; then
  while IFS='|' read -r cname ctype crelid ctarget cvalid; do
    [ -z "$cname" ] && continue
    TOTAL_CONSTRAINTS=$((TOTAL_CONSTRAINTS + 1))
    case "$ctype" in
      p)
        PK_COUNT=$((PK_COUNT + 1))
        CTYPE_LABEL="Primary Key"
        ;;
      f)
        FK_COUNT=$((FK_COUNT + 1))
        CTYPE_LABEL="Foreign Key (${crelid} -> ${ctarget})"
        ;;
      u)
        CTYPE_LABEL="Unique"
        ;;
      c)
        CTYPE_LABEL="Check"
        ;;
      *)
        CTYPE_LABEL="Other ($ctype)"
        ;;
    esac

    if [ "$cvalid" != "t" ]; then
      INVALID_CONSTRAINTS=$((INVALID_CONSTRAINTS + 1))
      STATUS="INVALID"
      echo "  [FAIL] $cname on $crelid ($CTYPE_LABEL) is NOT valid!"
    else
      STATUS="VALID"
      echo "  [PASS] $cname on $crelid ($CTYPE_LABEL): VALID"
    fi
    CONSTRAINT_DETAILS="${CONSTRAINT_DETAILS}
- \`${cname}\` on \`${crelid}\`: ${CTYPE_LABEL} (${STATUS})"
  done <<< "$CONSTRAINTS_RAW"
fi

echo "Summary: $TOTAL_CONSTRAINTS constraint(s) ($PK_COUNT PKs, $FK_COUNT FKs, $INVALID_CONSTRAINTS invalid)."
if [ "$INVALID_CONSTRAINTS" -gt 0 ]; then
  echo "::error::Integrity check failed: $INVALID_CONSTRAINTS invalid/corrupt constraints found in public schema."
  exit 1
fi

# 5. Index Integrity Validation
echo ""
echo "--- 4. Checking Index Integrity ---"
INDEXES_RAW=$(docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -At -F'|' -c \
  "SELECT c.relname, i.indisvalid, i.indisprimary, i.indisunique
   FROM pg_index i
   JOIN pg_class c ON c.oid = i.indexrelid
   JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
   ORDER BY c.relname;")

TOTAL_INDEXES=0
INVALID_INDEXES=0
if [ -n "$INDEXES_RAW" ]; then
  while IFS='|' read -r iname ivalid iprimary iunique; do
    [ -z "$iname" ] && continue
    TOTAL_INDEXES=$((TOTAL_INDEXES + 1))
    if [ "$ivalid" != "t" ]; then
      INVALID_INDEXES=$((INVALID_INDEXES + 1))
      echo "  [FAIL] Index $iname is INVALID!"
    else
      echo "  [PASS] Index $iname: VALID"
    fi
  done <<< "$INDEXES_RAW"
fi

echo "Summary: $TOTAL_INDEXES index(es), $INVALID_INDEXES invalid."
if [ "$INVALID_INDEXES" -gt 0 ]; then
  echo "::error::Integrity check failed: $INVALID_INDEXES invalid indexes found in public schema."
  exit 1
fi

# 6. Read-Viability Query Assertions
echo ""
echo "--- 5. Executing Read-Viability Query Assertions ---"
while IFS= read -r tbl; do
  [ -z "$tbl" ] && continue
  echo "Testing SELECT query on public.$tbl..."
  docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT * FROM public.\"$tbl\" LIMIT 5;" >/dev/null
  echo "  [PASS] SELECT on public.$tbl succeeded."
done <<< "$TABLE_LIST"

# If profiles and user_settings exist, perform explicit join test
if echo "$TABLE_LIST" | grep -q "^profiles$" && echo "$TABLE_LIST" | grep -q "^user_settings$"; then
  echo "Testing relational JOIN between profiles and user_settings..."
  docker exec "$CONTAINER_NAME" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
    "SELECT p.id, p.username, s.theme, s.notifications_enabled 
     FROM public.profiles p 
     LEFT JOIN public.user_settings s ON s.profile_id = p.id 
     LIMIT 5;" >/dev/null
  echo "  [PASS] Relational JOIN query succeeded."
fi

echo ""
echo "=========================================================="
echo "All Deep Restore Integrity Assertions Passed Successfully!"
echo "=========================================================="

# Export to GITHUB_OUTPUT if available
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "table_count=${TABLE_COUNT}"
    echo "pk_count=${PK_COUNT}"
    echo "fk_count=${FK_COUNT}"
    echo "index_count=${TOTAL_INDEXES}"
    echo "integrity_status=PASSED"
    echo "row_summary<<EOF"
    echo "$ROW_SUMMARY"
    echo "EOF"
  } >> "$GITHUB_OUTPUT"
fi
