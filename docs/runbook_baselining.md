# Operational Runbook: Database Baselining & Existing Project Adoption

This runbook provides step-by-step instructions for onboarding an existing Supabase or PostgreSQL database into this GitOps repository without data loss, downtime, or migration collision.

---

## 1. When to Use This Runbook

Use this runbook when:
- You have an active Supabase project with tables, views, functions, or data created directly via the Supabase Dashboard, Table Editor, or an external tool.
- You are migrating from manual database administration to version-controlled GitOps.
- Your remote database has historical migration records that are not currently tracked in this repository's `supabase/migrations/` directory.

> [!CAUTION]
> **Do not run `capture-supabase-migrations` or `deploy-migrations` before baselining.**
> Running automated deployment against an un-baselined database risks failing preflight audits or applying duplicate DDL. Running drift capture against an un-baselined database produces an unmanaged diff that lacks foundational schema definitions.

---

## 2. Prerequisites

1. **Supabase CLI**: Installed locally (`supabase --version` $\ge 2.121.0$).
2. **PostgreSQL Client Tools**: `psql` and `pg_dump` installed locally (PostgreSQL 15+).
3. **Database Connection String**: Direct connection URI (`postgresql://postgres.<project-ref>:<password>@<host>:5432/postgres`) exported to your environment:
   ```bash
   export SUPABASE_DB_URL="postgresql://postgres.<project-ref>:<password>@<host>:5432/postgres"
   ```

---

## 3. Step-by-Step Baselining Procedure

### Step 1: Inspect Remote Migration History

First, audit the current state of the remote database's migration tracking table:

```bash
psql "$SUPABASE_DB_URL" -c "
SELECT version, name, inserted_at 
FROM supabase_migrations.schema_migrations 
ORDER BY version ASC;
"
```

- **If table does not exist or has 0 rows**: Your remote database has never used Supabase CLI migrations. Proceed to Step 2.
- **If table contains rows**: Note the highest applied version timestamp.

---

### Step 2: Generate the Initial Baseline Migration

Export your existing `public` application schema structure (without data) using `supabase db dump`:

```bash
# Generate a monotonic 14-digit timestamp
TIMESTAMP=$(date -u +%Y%m%d%H%M%S)

# Dump the DDL for the public application schema
supabase db dump \
  --db-url "$SUPABASE_DB_URL" \
  --schema public \
  -f "supabase/migrations/${TIMESTAMP}_initial_baseline.sql"

echo "Generated baseline migration: supabase/migrations/${TIMESTAMP}_initial_baseline.sql"
```

Verify that the generated migration file contains your tables, foreign keys, views, and functions:

```bash
head -n 30 "supabase/migrations/${TIMESTAMP}_initial_baseline.sql"
```

---

### Step 3: Register the Baseline as Applied

Because this schema is *already live* on your remote database, running `supabase db push` would error attempting to re-create existing tables.

Register this baseline version in the remote tracking table without executing its DDL:

```bash
supabase migration repair \
  --status applied \
  "$TIMESTAMP" \
  --db-url "$SUPABASE_DB_URL"
```

Verify that the remote migration table now recognizes the baseline:

```bash
supabase migration list --db-url "$SUPABASE_DB_URL"
```

The output should show `${TIMESTAMP}` under both Local and Remote columns.

---

### Step 4: Reconcile Legacy Remote Migrations (If Any)

If Step 1 showed older migration versions on the remote database that do not exist as `.sql` files in your repository, you must reconcile them:

1. **Option A (Mark Reverted):** If those migrations represent legacy schema modifications now captured inside your new consolidated baseline:
   ```bash
   supabase migration repair --status reverted <LEGACY_VERSION_ID> --db-url "$SUPABASE_DB_URL"
   ```
2. **Option B (Preserve Files):** If you have the historical SQL files, place them in `supabase/migrations/` with their matching 14-digit timestamps before your baseline.

---

### Step 5: Commit and Push Baseline to GitHub

Commit your new baseline migration file to the `master` branch:

```bash
git add supabase/migrations/
git commit -m "chore(db): establish initial database schema baseline (${TIMESTAMP})"
git push origin master
```

---

## 4. Verification

1. Go to **Actions** in your GitHub repository.
2. Trigger the **Test and lint migrations** (`lint-migrations.yml`) workflow:
   - The workflow will spin up an isolated PostgreSQL 17 container.
   - It will apply your baseline migration and verify that all DDL executes cleanly from scratch.
3. Trigger the **Scheduled schema drift alert** (`drift-alert.yml`) workflow:
   - The workflow will run a dry-run comparison between your remote database and the baseline in Git.
   - It should report: `No schema drift detected. The remote database schema matches the local migrations.`

Your database is now fully baselined and governed by GitOps!
