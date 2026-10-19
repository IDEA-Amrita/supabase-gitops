create table public.members (
    uid         smallint generated always as identity
                    (start with 100 minvalue 100 maxvalue 999 no cycle) primary key,
    name        text not null check (length(trim(name)) > 0),
    dept        text not null check (length(trim(dept)) > 0),
    batch_year  int  not null check (batch_year between 1990 and 2100),
    role        text not null check (length(trim(role)) > 0),
    email       text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    is_active   boolean not null default true,
    joined_on   timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create unique index uq_members_email on public.members (lower(email));
create index idx_members_dept_active on public.members (dept) where is_active;

create table public.projects (
    pid         smallint generated always as identity
                    (start with 100 minvalue 100 maxvalue 999 no cycle) primary key,
    title       text not null check (length(trim(title)) > 0),
    ps          text,
    status      text not null default 'ongoing'
                    check (status in ('ongoing', 'completed', 'on_hold', 'cancelled')),
    start_date  date not null,
    end_date    date,
    team_lead   smallint references public.members(uid) on delete set null,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    check (end_date is null or end_date >= start_date),
    check (status <> 'completed' or end_date is not null)
);

create table public.project_members (
    pid         smallint not null references public.projects(pid) on delete cascade,
    uid         smallint not null references public.members(uid) on delete restrict,
    joined_on   timestamptz not null default now(),
    primary key (pid, uid)
);

create index idx_project_members_uid on public.project_members (uid);
create index idx_projects_team_lead  on public.projects (team_lead);
create index idx_projects_status     on public.projects (status);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create trigger trg_members_updated  before update on public.members
    for each row execute function public.set_updated_at();
create trigger trg_projects_updated before update on public.projects
    for each row execute function public.set_updated_at();

alter table public.members         enable row level security;
alter table public.projects        enable row level security;
alter table public.project_members enable row level security;

create policy "read members"         on public.members         for select to authenticated using (true);
create policy "read projects"        on public.projects        for select to authenticated using (true);
create policy "read project_members" on public.project_members for select to authenticated using (true);

create view public.member_projects with (security_invoker = true) as
select pm.uid,
       p.pid,
       p.title,
       p.status,
       (p.status in ('ongoing', 'on_hold')) as is_current
from public.project_members pm
join public.projects p using (pid);
