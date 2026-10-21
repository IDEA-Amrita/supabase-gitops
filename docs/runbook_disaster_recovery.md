# Operational Runbook: Database Disaster Recovery & Manual Restoration

This runbook outlines standard operating procedures for decrypting, validating, and restoring encrypted database backups created by the `backup-database.yml` workflow.

---

## 1. When to Use This Runbook

Use this runbook when:
- **Disaster Recovery**: Production database has experienced catastrophic data corruption, unrecoverable human error, or data loss.
- **Environment Hydration**: Populating a local development or staging environment with an authorized sanitized snapshot of application data.
- **Compliance Audit**: Auditing backup decryptability and data integrity for ISO 27001, SOC 2, or disaster readiness audits.

---

## 2. Prerequisites & Tooling

To restore an encrypted backup bundle, ensure the following utilities are installed:
- **GnuPG** (`gpg` $\ge 2.2$) for AES-256 decryption.
- **SHA-256 Utility** (`sha256sum` on Linux or `shasum -a 256` on macOS).
- **PostgreSQL Client** (`psql` $\ge 15$).
- **Backup Decryption Passphrase**: Secret `BACKUP_ENCRYPTION_KEY`.

---

## 3. Step-by-Step Restoration Procedure

### Step 1: Download and Extract the Backup Bundle

1. Navigate to **Actions** > **Backup database** in your repository.
2. Select the latest successful run and download the artifact bundle named `encrypted-database-backup-<timestamp>`.
3. Unzip the artifact bundle into a secure temporary directory:
   ```bash
   mkdir -p /tmp/recovery_drill
   cd /tmp/recovery_drill
   unzip ~/Downloads/encrypted-database-backup-*.zip
   ```
4. Confirm the directory contains:
   - `supabase_backup_<timestamp>.sql.gpg` (Encrypted payload)
   - `supabase_backup_<timestamp>.sql.gpg.sha256` (Cryptographic checksum)
   - `manifest.json` (Audit trail metadata)

---

### Step 2: Cryptographic Tamper-Evidence Verification

Before decrypting, verify the SHA-256 checksum to ensure the artifact was not corrupted in transit or tampered with:

```bash
sha256sum -c *.sha256
```

**Expected output:**
```
supabase_backup_20261021_020000.sql.gpg: OK
```

> [!CAUTION]
> If `sha256sum` reports `FAILED`, abort immediately. The backup file is incomplete, corrupt, or compromised.

---

### Step 3: Secure Decryption

Decrypt the AES-256 ciphertext directly using `gpg`:

```bash
# Set secure umask so plaintext is only readable by current user
umask 077

# Decrypt backup payload
gpg --batch --yes --decrypt \
  --passphrase-fd 0 \
  -o restore_plaintext.sql \
  supabase_backup_*.sql.gpg <<< "$BACKUP_ENCRYPTION_KEY"

# Verify non-empty plaintext
ls -lh restore_plaintext.sql
head -n 20 restore_plaintext.sql
```

---

### Step 4: Restore to Target PostgreSQL Database

Set your target database connection string.

> [!WARNING]
> **Safety Warning:** Ensure `TARGET_DB_URL` points to your intended disaster recovery target or ephemeral staging instance. **Do not run this command against an unintended database!**

```bash
export TARGET_DB_URL="postgresql://postgres:<password>@<target-host>:5432/postgres"

# Execute restoration with strict error halting
psql "$TARGET_DB_URL" \
  -v ON_ERROR_STOP=1 \
  --single-transaction \
  -f restore_plaintext.sql
```

---

## 4. Post-Restore Verification Checklist

Execute the deep assertions below to certify the database is fully operational:

### 1. Table Inventory Check
Verify that all application tables exist in the `public` schema:
```bash
psql "$TARGET_DB_URL" -c "
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name;
"
```

### 2. Row Count and Integrity Verification
Verify row counts across key tables match expectations:
```bash
psql "$TARGET_DB_URL" -c "
SELECT relname AS table_name, n_live_tup AS estimated_rows
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY relname;
"
```

### 3. Constraint & Foreign Key Validation
Verify all constraints are valid and not marked invalid or broken:
```bash
psql "$TARGET_DB_URL" -c "
SELECT conname, contype, conrelid::regclass 
FROM pg_constraint 
WHERE connamespace = 'public'::regnamespace;
"
```

### 4. Index Verification
Verify that primary key and secondary indexes were created:
```bash
psql "$TARGET_DB_URL" -c "
SELECT indexname, tablename 
FROM pg_indexes 
WHERE schemaname = 'public' 
ORDER BY tablename, indexname;
"
```

---

## 5. Secure Cleanup

Once restoration and verification are complete, securely purge plaintext files from the operator workstation:

```bash
shred -u restore_plaintext.sql 2>/dev/null || rm -f restore_plaintext.sql
rm -rf /tmp/recovery_drill
echo "Plaintext recovery artifacts securely destroyed."
```

---

## 6. Common Troubleshooting

| Issue / Error | Root Cause | Remediation |
|---|---|---|
| `gpg: decryption failed: Bad session key` | Incorrect passphrase supplied in `$BACKUP_ENCRYPTION_KEY`. | Verify the exact string stored in repository secret `BACKUP_ENCRYPTION_KEY`. |
| `ERROR: role "authenticated" does not exist` | Target PostgreSQL instance lacks standard Supabase roles. | Re-create standard mock roles: `CREATE ROLE authenticated NOLOGIN; CREATE ROLE anon NOLOGIN; CREATE ROLE service_role NOLOGIN;` |
| `ERROR: relation "public.foo" already exists` | Target database already has conflicting tables. | Either supply `--clean` flag during dump, run restoration on an empty target database, or drop public schema prior to restore (`DROP SCHEMA public CASCADE; CREATE SCHEMA public;`). |
| `ERROR: permission denied for schema auth` | Restoring dump that attempts to reference system tables. | Ensure dump was generated with `--schema=public`. |
