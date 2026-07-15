-- ============================================================
-- SITE-416 :: DEPARTMENT OF INTERNAL AUDITING
-- Supabase Schema — you already ran this once successfully.
-- Kept here for reference / re-deployment only.
-- ============================================================

create extension if not exists "uuid-ossp";

create type access_role as enum ('viewer', 'auditor', 'supervisor', 'admin');
create type record_status as enum ('active', 'reassigned', 'terminated', 'reserve');

create table invite_codes (
  code text primary key,
  division text not null,
  rank text not null,
  role access_role not null default 'viewer',
  clearance_level int not null default 1 check (clearance_level between 1 and 5),
  note text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  used boolean not null default false,
  used_by uuid references auth.users(id),
  used_at timestamptz
);

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  callsign text,
  division text not null,
  rank text not null,
  role access_role not null default 'viewer',
  clearance_level int not null default 1 check (clearance_level between 1 and 5),
  status record_status not null default 'active',
  joined_at timestamptz not null default now()
);

create table personnel_records (
  id uuid primary key default uuid_generate_v4(),
  full_name text not null,
  callsign text,
  division text not null,
  rank text not null,
  status record_status not null default 'active',
  clearance_level int not null default 1 check (clearance_level between 1 and 5),
  notes text,
  linked_profile uuid references profiles(id),
  created_by uuid references profiles(id),
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create table documents (
  id uuid primary key default uuid_generate_v4(),
  title text not null,
  division text not null,
  classification_level int not null default 1 check (classification_level between 1 and 5),
  body text not null default '',
  author uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table audit_logs (
  id uuid primary key default uuid_generate_v4(),
  actor uuid references profiles(id),
  action text not null,
  target_table text,
  target_id uuid,
  detail jsonb,
  created_at timestamptz not null default now()
);

create or replace function redeem_invite_code(
  p_code text,
  p_full_name text,
  p_callsign text default null
)
returns profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite invite_codes;
  v_profile profiles;
begin
  select * into v_invite from invite_codes where code = p_code for update;

  if v_invite is null then
    raise exception 'Invalid invite code.';
  end if;

  if v_invite.used then
    raise exception 'This invite code has already been used.';
  end if;

  if v_invite.expires_at is not null and v_invite.expires_at < now() then
    raise exception 'This invite code has expired.';
  end if;

  insert into profiles (id, full_name, callsign, division, rank, role, clearance_level)
  values (auth.uid(), p_full_name, p_callsign, v_invite.division, v_invite.rank, v_invite.role, v_invite.clearance_level)
  returning * into v_profile;

  update invite_codes
    set used = true, used_by = auth.uid(), used_at = now()
    where code = p_code;

  insert into audit_logs (actor, action, target_table, target_id, detail)
  values (auth.uid(), 'account.created', 'profiles', v_profile.id,
          jsonb_build_object('division', v_invite.division, 'rank', v_invite.rank));

  return v_profile;
end;
$$;

grant execute on function redeem_invite_code(text, text, text) to authenticated;

create or replace function current_profile()
returns profiles
language sql
security definer
stable
set search_path = public
as $$
  select * from profiles where id = auth.uid();
$$;

grant execute on function current_profile() to authenticated;

alter table invite_codes enable row level security;
alter table profiles enable row level security;
alter table personnel_records enable row level security;
alter table documents enable row level security;
alter table audit_logs enable row level security;

create policy "admins manage invite codes"
  on invite_codes for all
  using (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin'))
  with check (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin'));

create policy "users read own profile"
  on profiles for select
  using (auth.uid() = id);

create policy "supervisors/admins read profiles in scope"
  on profiles for select
  using (
    (select role from profiles where id = auth.uid()) = 'admin'
    or (
      (select role from profiles where id = auth.uid()) = 'supervisor'
      and division = (select division from profiles where id = auth.uid())
    )
  );

create policy "users update limited own fields"
  on profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

create policy "admins update any profile"
  on profiles for update
  using ((select role from profiles where id = auth.uid()) = 'admin');

create policy "viewers+ read personnel in division"
  on personnel_records for select
  using (
    (select role from profiles where id = auth.uid()) = 'admin'
    or division = (select division from profiles where id = auth.uid())
  );

create policy "supervisors+ write personnel in division"
  on personnel_records for insert
  with check (
    (select role from profiles where id = auth.uid()) in ('supervisor','admin')
    and (
      (select role from profiles where id = auth.uid()) = 'admin'
      or division = (select division from profiles where id = auth.uid())
    )
  );

create policy "supervisors+ update personnel in division"
  on personnel_records for update
  using (
    (select role from profiles where id = auth.uid()) = 'admin'
    or (
      (select role from profiles where id = auth.uid()) = 'supervisor'
      and division = (select division from profiles where id = auth.uid())
    )
  );

create policy "division members read documents up to their clearance"
  on documents for select
  using (
    (select role from profiles where id = auth.uid()) = 'admin'
    or (
      division = (select division from profiles where id = auth.uid())
      and classification_level <= (select clearance_level from profiles where id = auth.uid())
    )
  );

create policy "auditors+ create documents in own division"
  on documents for insert
  with check (
    (select role from profiles where id = auth.uid()) in ('auditor','supervisor','admin')
    and (
      (select role from profiles where id = auth.uid()) = 'admin'
      or division = (select division from profiles where id = auth.uid())
    )
  );

create policy "author or supervisor+ can update document"
  on documents for update
  using (
    author = auth.uid()
    or (select role from profiles where id = auth.uid()) in ('supervisor','admin')
  );

create policy "supervisors+ read audit log"
  on audit_logs for select
  using ((select role from profiles where id = auth.uid()) in ('supervisor','admin'));

create policy "any authenticated user can write a log entry"
  on audit_logs for insert
  with check (auth.uid() = actor);

insert into invite_codes (code, division, rank, role, clearance_level, note)
values ('SITE416-ROOT-ADMIN-0001', 'Directorate', 'Director', 'admin', 5, 'Bootstrap admin code — rotate/delete after first use')
on conflict (code) do nothing;
