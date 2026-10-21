#!/usr/bin/env python3
import sys
import subprocess
import re
from datetime import datetime, timezone

def run_query(target, query, is_docker=True):
    if is_docker:
        cmd = ["docker", "exec", "-i", target, "psql", "-U", "postgres", "-d", "postgres", "-At"]
    else:
        cmd = ["psql", target, "--no-psqlrc", "-At"]
    
    res = subprocess.run(cmd, input=query, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"Database query failed: {res.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    
    return [line.split("|") for line in res.stdout.strip().split("\n") if line.strip()]

def build_schema_documentation(target, is_docker=True):
    # 1. Fetch tables
    q_tables = "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY table_name;"
    table_rows = run_query(target, q_tables, is_docker)
    tables = [r[0] for r in table_rows if r and r[0]]
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    if not tables:
        return f"# Database Schema Documentation\n\n> Auto-generated on `{now}`.\n\n*No public tables detected. Add migration files to `supabase/migrations/` and apply them to generate entity relationship diagrams and schema documentation.*"

    # 2. Fetch table descriptions (comments)
    q_comments = """
    SELECT c.relname, COALESCE(d.description, '')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d ON d.objoid = c.oid AND d.objsubid = 0
    WHERE n.nspname = 'public' AND c.relkind = 'r';
    """
    comment_rows = run_query(target, q_comments, is_docker)
    table_comments = {r[0]: r[1] for r in comment_rows if len(r) >= 2 and r[1]}

    # 3. Fetch columns
    q_cols = """
    SELECT table_name, column_name, data_type, is_nullable, COALESCE(column_default, '')
    FROM information_schema.columns
    WHERE table_schema = 'public'
    ORDER BY table_name, ordinal_position;
    """
    col_rows = run_query(target, q_cols, is_docker)

    # 4. Fetch Primary Keys (supporting single and composite PKs)
    q_pks = """
    SELECT
      c.conrelid::regclass::text AS table_name,
      c.conname AS constraint_name,
      pg_get_constraintdef(c.oid) AS constraint_def
    FROM pg_constraint c
    JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE n.nspname = 'public' AND c.contype = 'p';
    """
    pk_rows = run_query(target, q_pks, is_docker)
    table_pks = {}
    pks_set = set()
    for r in pk_rows:
        if len(r) >= 3:
            tname = r[0].replace('"', '').replace('public.', '')
            cdef = r[2] # e.g. PRIMARY KEY (user_id, project_id)
            m = re.search(r'\((.*?)\)', cdef)
            if m:
                cols = [c.strip().replace('"', '') for c in m.group(1).split(',')]
                table_pks[tname] = cols
                for c in cols:
                    pks_set.add((tname, c))

    # 5. Fetch Foreign Keys (supporting single and multi-column FKs)
    q_fks = """
    SELECT
      c.conrelid::regclass::text AS source_table,
      c.confrelid::regclass::text AS target_table,
      c.conname AS constraint_name,
      pg_get_constraintdef(c.oid) AS constraint_def
    FROM pg_constraint c
    JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE n.nspname = 'public' AND c.contype = 'f';
    """
    fk_rows = run_query(target, q_fks, is_docker)
    parsed_fks = []
    for r in fk_rows:
        if len(r) >= 4:
            src = r[0].replace('"', '').replace('public.', '')
            tgt = r[1].replace('"', '').replace('public.', '')
            cname = r[2]
            cdef = r[3] # e.g. FOREIGN KEY (user_id) REFERENCES profiles(id)
            parsed_fks.append({
                "source": src,
                "target": tgt,
                "name": cname,
                "def": cdef
            })

    columns_by_table = {}
    for r in col_rows:
        if len(r) >= 5:
            tname, cname, dtype, nullable, default_val = r[0], r[1], r[2], r[3], r[4]
            columns_by_table.setdefault(tname, []).append({
                "name": cname,
                "type": dtype,
                "nullable": nullable,
                "default": default_val,
                "is_pk": (tname, cname) in pks_set
            })

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    lines = []
    lines.append("# Database Schema Documentation")
    lines.append("")
    lines.append(f"> Auto-generated from database schema on `{now}`.")
    lines.append("")
    lines.append("## Entity Relationship Diagram")
    lines.append("")
    lines.append("```mermaid")
    lines.append("erDiagram")

    for fk in parsed_fks:
        lines.append(f"    {fk['target']} ||--o{{ {fk['source']} : \"{fk['name']}\"")

    for tname in tables:
        lines.append(f"    {tname} {{")
        for col in columns_by_table.get(tname, []):
            clean_type = col["type"].replace(" ", "_")
            pk_mark = " PK" if col["is_pk"] else ""
            lines.append(f"        {clean_type} {col['name']}{pk_mark}")
        lines.append("    }")
    lines.append("```")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("## Tables Directory")
    lines.append("")

    for tname in tables:
        desc = table_comments.get(tname, "")
        lines.append(f"### `{tname}`")
        if desc:
            lines.append(f"> **Description**: {desc}")
            lines.append("")
        pk_cols = table_pks.get(tname, [])
        if len(pk_cols) > 1:
            lines.append(f"> **Composite Primary Key**: `({', '.join(pk_cols)})`")
            lines.append("")
        
        table_fk_defs = [f for f in parsed_fks if f["source"] == tname]
        if table_fk_defs:
            lines.append("**Foreign Key Constraints:**")
            for f in table_fk_defs:
                lines.append(f"- `{f['name']}`: `{f['def']}`")
            lines.append("")

        lines.append("| Column | Type | Nullable | Default | Key |")
        lines.append("|---|---|---|---|---|")
        for col in columns_by_table.get(tname, []):
            c_name = f"`{col['name']}`"
            c_type = f"`{col['type']}`"
            nullable_str = "YES" if col["nullable"] == "YES" else "NO"
            default_str = f"`{col['default']}`" if col["default"] else "-"
            key_str = "PRIMARY KEY" if col["is_pk"] else "-"
            lines.append(f"| {c_name} | {c_type} | {nullable_str} | {default_str} | {key_str} |")
        lines.append("")

    return "\n".join(lines)

def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "pg-doc-target"
    out_file = sys.argv[2] if len(sys.argv) > 2 else "docs/schema.md"
    is_docker = not (target.startswith("postgres://") or target.startswith("postgresql://"))

    doc = build_schema_documentation(target, is_docker=is_docker)
    with open(out_file, "w") as f:
        f.write(doc + "\n")
    print(f"Generated {out_file} successfully.")

if __name__ == "__main__":
    main()
