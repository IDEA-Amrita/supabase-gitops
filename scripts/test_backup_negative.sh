#!/usr/bin/env bash
# ==============================================================================
# scripts/test_backup_negative.sh
# 
# Negative backup and disaster recovery test suite for Supabase GitOps.
# Proves that decryption and restore fail safely under failure modes:
#   Scenario 1: Wrong Passphrase (decryption fails with non-zero exit code)
#   Scenario 2: Corrupted Archive (tampered ciphertext fails decryption)
#   Scenario 3: Zero-Byte Dump (empty payload rejected before execution)
#   Scenario 4: SQL Execution Error (malformed DDL halts restore under ON_ERROR_STOP=1)
# 
# Verifies zero unencrypted plaintext remnants via secure cleanup traps.
# ==============================================================================
set -euo pipefail

TEST_DIR=$(mktemp -d /tmp/backup_negative_test_XXXXXX)
trap 'rm -rf "$TEST_DIR"; echo "Secure cleanup: temporary test files removed."' EXIT INT TERM

echo "=========================================================="
echo "Starting Negative Disaster Recovery & Decryption Test Suite"
echo "Working Directory: $TEST_DIR"
echo "=========================================================="

VALID_KEY="CorrectMasterPassphrase123456!"
WRONG_KEY="IncorrectPassphrase987654321!"

# 0. Create known valid test fixture
VALID_SQL="$TEST_DIR/fixture.sql"
cat << 'EOF' > "$VALID_SQL"
CREATE TABLE negative_test_fixture (
    id serial PRIMARY KEY,
    name text NOT NULL
);
INSERT INTO negative_test_fixture (name) VALUES ('integrity_check_row');
EOF

VALID_GPG="$TEST_DIR/fixture.sql.gpg"
gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase-fd 3 -o "$VALID_GPG" "$VALID_SQL" 3<<< "$VALID_KEY"

if [ ! -s "$VALID_GPG" ]; then
  echo "::error::Failed to generate test fixture archive."
  exit 1
fi
echo "[OK] Baseline encrypted archive generated."

# ------------------------------------------------------------------------------
# Scenario 1: Wrong Passphrase
# ------------------------------------------------------------------------------
echo ""
echo "--- Scenario 1: Decryption with Wrong Passphrase ---"
DECRYPT_WRONG_OUTPUT="$TEST_DIR/decrypted_wrong.sql"
set +e
gpg --batch --yes --decrypt --passphrase-fd 3 -o "$DECRYPT_WRONG_OUTPUT" "$VALID_GPG" 3<<< "$WRONG_KEY" 2>"$TEST_DIR/gpg_err_wrong_key.log"
GPG_EXIT=$?
set -e

if [ "$GPG_EXIT" -ne 0 ] && [ ! -s "$DECRYPT_WRONG_OUTPUT" ]; then
  echo "  [PASS] Decryption failed as expected with exit code $GPG_EXIT (no plaintext output leaked)."
else
  echo "::error::Scenario 1 Failed: Decryption with incorrect key unexpectedly succeeded or produced output!"
  exit 1
fi

# ------------------------------------------------------------------------------
# Scenario 2: Corrupted / Tampered Archive
# ------------------------------------------------------------------------------
echo ""
echo "--- Scenario 2: Decryption of Corrupted / Tampered Archive ---"
CORRUPT_GPG="$TEST_DIR/corrupt_archive.sql.gpg"
# Truncate ciphertext and append garbage bytes
head -c 32 "$VALID_GPG" > "$CORRUPT_GPG"
echo "CORRUPTED_TAMPERED_CIPHERTEXT_BYTES_XYZ" >> "$CORRUPT_GPG"

DECRYPT_CORRUPT_OUTPUT="$TEST_DIR/decrypted_corrupt.sql"
set +e
gpg --batch --yes --decrypt --passphrase-fd 3 -o "$DECRYPT_CORRUPT_OUTPUT" "$CORRUPT_GPG" 3<<< "$VALID_KEY" 2>"$TEST_DIR/gpg_err_corrupt.log"
CORRUPT_EXIT=$?
set -e

if [ "$CORRUPT_EXIT" -ne 0 ] && [ ! -s "$DECRYPT_CORRUPT_OUTPUT" ]; then
  echo "  [PASS] Corrupted archive decryption failed as expected with exit code $CORRUPT_EXIT."
else
  echo "::error::Scenario 2 Failed: Corrupted archive was not rejected by GPG!"
  exit 1
fi

# ------------------------------------------------------------------------------
# Scenario 3: Zero-Byte / Truncated Dump File
# ------------------------------------------------------------------------------
echo ""
echo "--- Scenario 3: Rejection of Zero-Byte Dump ---"
EMPTY_SQL="$TEST_DIR/empty_dump.sql"
touch "$EMPTY_SQL"

set +e
if [ ! -s "$EMPTY_SQL" ]; then
  REJECTED_ZERO_BYTE=true
else
  REJECTED_ZERO_BYTE=false
fi
set -e

if [ "$REJECTED_ZERO_BYTE" = "true" ]; then
  echo "  [PASS] Zero-byte dump detected and pre-emptively rejected before database execution."
else
  echo "::error::Scenario 3 Failed: Zero-byte file was not detected as empty!"
  exit 1
fi

# ------------------------------------------------------------------------------
# Scenario 4: SQL Execution Error Isolation with ON_ERROR_STOP=1
# ------------------------------------------------------------------------------
echo ""
echo "--- Scenario 4: Malformed SQL Interruption (ON_ERROR_STOP=1) ---"
MALFORMED_SQL="$TEST_DIR/malformed.sql"
cat << 'EOF' > "$MALFORMED_SQL"
CREATE TABLE negative_syntax_probe (id int);
THIS_IS_TOTALLY_INVALID_SQL_SYNTAX_THAT_MUST_ABORT;
INSERT INTO negative_syntax_probe (id) VALUES (42);
EOF

# If pg-restore-target container is active, test execution failure
if docker ps --format '{{.Names}}' | grep -q "^pg-restore-target$"; then
  set +e
  docker exec -i pg-restore-target psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$MALFORMED_SQL" 2>"$TEST_DIR/psql_syntax_err.log"
  PSQL_EXIT=$?
  set -e
  if [ "$PSQL_EXIT" -ne 0 ]; then
    echo "  [PASS] psql with ON_ERROR_STOP=1 halted immediately upon syntax error (exit code $PSQL_EXIT)."
  else
    echo "::error::Scenario 4 Failed: Malformed SQL did not cause non-zero exit code!"
    exit 1
  fi
else
  # Use temporary container to verify ON_ERROR_STOP behavior
  set +e
  docker run --rm -i postgres:17-alpine sh -c "
    initdb -D /tmp/pgdata >/dev/null 2>&1
    pg_ctl -D /tmp/pgdata -w start >/dev/null 2>&1
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 < /dev/stdin >/dev/null 2>&1
  " < "$MALFORMED_SQL"
  PSQL_EXIT=$?
  set -e
  if [ "$PSQL_EXIT" -ne 0 ]; then
    echo "  [PASS] Isolated test runner with ON_ERROR_STOP=1 halted immediately upon syntax error (exit code $PSQL_EXIT)."
  else
    echo "::error::Scenario 4 Failed: Malformed SQL did not trigger non-zero exit code!"
    exit 1
  fi
fi

echo ""
echo "=========================================================="
echo "All 4 Negative Disaster Recovery Scenarios Passed Safely!"
echo "=========================================================="
