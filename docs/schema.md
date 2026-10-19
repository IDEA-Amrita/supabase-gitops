# Database Schema Documentation

> Auto-generated from database schema on `2026-10-19 18:59:48 UTC`.

## Entity Relationship Diagram

```mermaid
erDiagram
    members ||--o{ projects : "references (team_lead)"
    projects ||--o{ project_members : "references (pid)"
    members ||--o{ project_members : "references (uid)"
    members {
        smallint uid PK
        text name
        text dept
        integer batch_year
        text role
        text email
        boolean is_active
        timestamp_with_time_zone joined_on
        timestamp_with_time_zone updated_at
    }
    project_members {
        smallint pid PK
        smallint uid PK
        timestamp_with_time_zone joined_on
    }
    projects {
        smallint pid PK
        text title
        text ps
        text status
        date start_date
        date end_date
        smallint team_lead
        timestamp_with_time_zone created_at
        timestamp_with_time_zone updated_at
    }
```

---

## Tables Directory

### `members`

| Column | Type | Nullable | Default | Key |
|---|---|---|---|---|
| `uid` | `smallint` | NO | - | PRIMARY KEY |
| `name` | `text` | NO | - | - |
| `dept` | `text` | NO | - | - |
| `batch_year` | `integer` | NO | - | - |
| `role` | `text` | NO | - | - |
| `email` | `text` | NO | - | - |
| `is_active` | `boolean` | NO | `true` | - |
| `joined_on` | `timestamp with time zone` | NO | `now()` | - |
| `updated_at` | `timestamp with time zone` | NO | `now()` | - |

### `project_members`

| Column | Type | Nullable | Default | Key |
|---|---|---|---|---|
| `pid` | `smallint` | NO | - | PRIMARY KEY |
| `uid` | `smallint` | NO | - | PRIMARY KEY |
| `joined_on` | `timestamp with time zone` | NO | `now()` | - |

### `projects`

| Column | Type | Nullable | Default | Key |
|---|---|---|---|---|
| `pid` | `smallint` | NO | - | PRIMARY KEY |
| `title` | `text` | NO | - | - |
| `ps` | `text` | YES | - | - |
| `status` | `text` | NO | `'ongoing'::text` | - |
| `start_date` | `date` | NO | - | - |
| `end_date` | `date` | YES | - | - |
| `team_lead` | `smallint` | YES | - | - |
| `created_at` | `timestamp with time zone` | NO | `now()` | - |
| `updated_at` | `timestamp with time zone` | NO | `now()` | - |

