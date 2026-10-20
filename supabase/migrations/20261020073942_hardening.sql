alter table public.members drop constraint members_roll_no_format;

alter table public.members
    add constraint members_roll_no_format
        check (roll_no ~ '^[a-z0-9][a-z0-9_/-]*$' and length(roll_no) <= 30),
    add constraint members_name_len  check (length(name)  <= 100),
    add constraint members_dept_len  check (length(dept)  <= 50),
    add constraint members_role_len  check (length(role)  <= 50),
    add constraint members_email_len check (length(email) <= 254);

alter table public.projects
    add constraint projects_title_len check (length(title) <= 150),
    add constraint projects_ps_len    check (ps is null or length(ps) <= 5000);


create or replace view public.member_projects with (security_invoker = true) as
select pm.uid,
       p.pid,
       p.title,
       p.status,
       (p.status in ('ongoing', 'on_hold')) as is_current,
       (p.team_lead = pm.uid)               as is_lead
from public.project_members pm
join public.projects p using (pid)
union
select p.team_lead,
       p.pid,
       p.title,
       p.status,
       (p.status in ('ongoing', 'on_hold')),
       true
from public.projects p
where p.team_lead is not null;


revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;

alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;


grant select (uid, name, dept, batch_year, role, roll_no, is_active, joined_on, updated_at)
    on public.members to authenticated;
grant select on public.projects        to authenticated;
grant select on public.project_members to authenticated;
grant select on public.member_projects to authenticated;


comment on table  public.members         is 'People. roll_no is the search key; uid is the internal key.';
comment on table  public.projects        is 'Projects. team_lead need not be an assigned member.';
comment on table  public.project_members is 'Assignments. All members of a project share one role.';
comment on column public.members.roll_no is 'Lowercase, trimmed, unique.';
comment on column public.members.ph_no   is 'Optional. Exactly 10 digits. NULL when absent, never empty string.';
comment on view   public.member_projects is 'Projects per member, including projects they lead without being assigned.';