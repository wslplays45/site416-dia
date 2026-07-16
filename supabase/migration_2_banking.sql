-- ============================================================
-- SITE-416 :: MIGRATION 2
-- Banking system + department-wide documents
-- Run this in the Supabase SQL Editor (your existing tables/data
-- are untouched — this only adds new things).
-- ============================================================

-- ------------------------------------------------------------
-- 1. New columns on existing tables
-- ------------------------------------------------------------
alter table profiles add column if not exists is_banking_staff boolean not null default false;
alter table invite_codes add column if not exists is_banking_staff boolean not null default false;
alter table documents add column if not exists department_wide boolean not null default false;

-- ------------------------------------------------------------
-- 2. Banking tables
-- ------------------------------------------------------------
create table if not exists bank_accounts (
  id uuid primary key default uuid_generate_v4(),
  profile_id uuid not null unique references profiles(id) on delete cascade,
  balance numeric(12,2) not null default 0,
  created_at timestamptz not null default now()
);

do $$ begin
  create type transaction_type as enum ('deposit', 'withdrawal', 'transfer_in', 'transfer_out');
exception
  when duplicate_object then null;
end $$;

create table if not exists bank_transactions (
  id uuid primary key default uuid_generate_v4(),
  account_id uuid not null references bank_accounts(id) on delete cascade,
  type transaction_type not null,
  amount numeric(12,2) not null check (amount > 0),
  balance_after numeric(12,2) not null,
  related_account_id uuid references bank_accounts(id),
  performed_by uuid references profiles(id),
  note text,
  created_at timestamptz not null default now()
);

alter table bank_accounts enable row level security;
alter table bank_transactions enable row level security;

-- ------------------------------------------------------------
-- 3. Backfill: give every existing profile a bank account
-- ------------------------------------------------------------
insert into bank_accounts (profile_id)
select id from profiles
where id not in (select profile_id from bank_accounts)
on conflict (profile_id) do nothing;

-- ------------------------------------------------------------
-- 4. Update redeem_invite_code() to also create a bank account
--    and carry over the is_banking_staff flag
-- ------------------------------------------------------------
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

  insert into profiles (id, full_name, callsign, division, rank, role, clearance_level, is_banking_staff)
  values (auth.uid(), p_full_name, p_callsign, v_invite.division, v_invite.rank, v_invite.role, v_invite.clearance_level, v_invite.is_banking_staff)
  returning * into v_profile;

  insert into bank_accounts (profile_id) values (v_profile.id);

  update invite_codes
    set used = true, used_by = auth.uid(), used_at = now()
    where code = p_code;

  insert into audit_logs (actor, action, target_table, target_id, detail)
  values (auth.uid(), 'account.created', 'profiles', v_profile.id,
          jsonb_build_object('division', v_invite.division, 'rank', v_invite.rank));

  return v_profile;
end;
$$;

-- ------------------------------------------------------------
-- 5. Banking operation functions (all writes go through these —
--    balances are never edited directly from the frontend)
-- ------------------------------------------------------------
create or replace function bank_deposit(p_account_id uuid, p_amount numeric, p_note text default null)
returns bank_accounts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller profiles;
  v_account bank_accounts;
begin
  select * into v_caller from current_profile();
  if v_caller.role != 'admin' and coalesce(v_caller.is_banking_staff, false) = false then
    raise exception 'Not authorized to perform banking transactions.';
  end if;

  if p_amount <= 0 then
    raise exception 'Amount must be positive.';
  end if;

  update bank_accounts set balance = balance + p_amount
    where id = p_account_id
    returning * into v_account;

  if v_account is null then
    raise exception 'Account not found.';
  end if;

  insert into bank_transactions (account_id, type, amount, balance_after, performed_by, note)
  values (p_account_id, 'deposit', p_amount, v_account.balance, v_caller.id, p_note);

  return v_account;
end;
$$;

create or replace function bank_withdraw(p_account_id uuid, p_amount numeric, p_note text default null)
returns bank_accounts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller profiles;
  v_account bank_accounts;
begin
  select * into v_caller from current_profile();
  if v_caller.role != 'admin' and coalesce(v_caller.is_banking_staff, false) = false then
    raise exception 'Not authorized to perform banking transactions.';
  end if;

  if p_amount <= 0 then
    raise exception 'Amount must be positive.';
  end if;

  select * into v_account from bank_accounts where id = p_account_id for update;
  if v_account is null then
    raise exception 'Account not found.';
  end if;
  if v_account.balance < p_amount then
    raise exception 'Insufficient funds.';
  end if;

  update bank_accounts set balance = balance - p_amount
    where id = p_account_id
    returning * into v_account;

  insert into bank_transactions (account_id, type, amount, balance_after, performed_by, note)
  values (p_account_id, 'withdrawal', p_amount, v_account.balance, v_caller.id, p_note);

  return v_account;
end;
$$;

create or replace function bank_transfer(p_from_account uuid, p_to_account uuid, p_amount numeric, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller profiles;
  v_from bank_accounts;
  v_to bank_accounts;
begin
  select * into v_caller from current_profile();
  if v_caller.role != 'admin' and coalesce(v_caller.is_banking_staff, false) = false then
    raise exception 'Not authorized to perform banking transactions.';
  end if;

  if p_amount <= 0 then
    raise exception 'Amount must be positive.';
  end if;

  if p_from_account = p_to_account then
    raise exception 'Cannot transfer an account to itself.';
  end if;

  select * into v_from from bank_accounts where id = p_from_account for update;
  select * into v_to from bank_accounts where id = p_to_account for update;

  if v_from is null or v_to is null then
    raise exception 'One or both accounts were not found.';
  end if;
  if v_from.balance < p_amount then
    raise exception 'Insufficient funds.';
  end if;

  update bank_accounts set balance = balance - p_amount where id = p_from_account returning * into v_from;
  update bank_accounts set balance = balance + p_amount where id = p_to_account returning * into v_to;

  insert into bank_transactions (account_id, type, amount, balance_after, related_account_id, performed_by, note)
  values (p_from_account, 'transfer_out', p_amount, v_from.balance, p_to_account, v_caller.id, p_note);

  insert into bank_transactions (account_id, type, amount, balance_after, related_account_id, performed_by, note)
  values (p_to_account, 'transfer_in', p_amount, v_to.balance, p_from_account, v_caller.id, p_note);
end;
$$;

create or replace function bank_search_accounts(p_query text default '')
returns table (
  account_id uuid,
  profile_id uuid,
  full_name text,
  callsign text,
  division text,
  rank text,
  balance numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller profiles;
begin
  select * into v_caller from current_profile();
  if v_caller.role != 'admin' and coalesce(v_caller.is_banking_staff, false) = false then
    raise exception 'Not authorized.';
  end if;

  return query
  select a.id, p.id, p.full_name, p.callsign, p.division, p.rank, a.balance
  from bank_accounts a
  join profiles p on p.id = a.profile_id
  where p.full_name ilike '%' || p_query || '%' or p.callsign ilike '%' || p_query || '%'
  order by p.full_name
  limit 25;
end;
$$;

create or replace function set_banking_staff(p_profile_id uuid, p_value boolean)
returns profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller profiles;
  v_profile profiles;
begin
  select * into v_caller from current_profile();
  if v_caller.role != 'admin' then
    raise exception 'Only admins can grant banking staff access.';
  end if;

  update profiles set is_banking_staff = p_value
    where id = p_profile_id
    returning * into v_profile;

  return v_profile;
end;
$$;

grant execute on function bank_deposit(uuid, numeric, text) to authenticated;
grant execute on function bank_withdraw(uuid, numeric, text) to authenticated;
grant execute on function bank_transfer(uuid, uuid, numeric, text) to authenticated;
grant execute on function bank_search_accounts(text) to authenticated;
grant execute on function set_banking_staff(uuid, boolean) to authenticated;

-- ------------------------------------------------------------
-- 6. RLS for banking tables
--    (all writes go through the SECURITY DEFINER functions
--    above, so no client-facing insert/update policies needed)
-- ------------------------------------------------------------
drop policy if exists "own account or banking staff/admin read accounts" on bank_accounts;
create policy "own account or banking staff/admin read accounts"
  on bank_accounts for select
  using (
    profile_id = auth.uid()
    or (select is_banking_staff from current_profile()) = true
    or (select role from current_profile()) = 'admin'
  );

drop policy if exists "own transactions or banking staff/admin read transactions" on bank_transactions;
create policy "own transactions or banking staff/admin read transactions"
  on bank_transactions for select
  using (
    exists (select 1 from bank_accounts a where a.id = bank_transactions.account_id and a.profile_id = auth.uid())
    or (select is_banking_staff from current_profile()) = true
    or (select role from current_profile()) = 'admin'
  );

-- ------------------------------------------------------------
-- 7. Department-wide documents: update documents RLS
-- ------------------------------------------------------------
drop policy if exists "division members read documents up to their clearance" on documents;
create policy "read documents by division or department-wide, gated by clearance"
  on documents for select
  using (
    (select role from current_profile()) = 'admin'
    or (
      classification_level <= (select clearance_level from current_profile())
      and (
        department_wide = true
        or division = (select division from current_profile())
      )
    )
  );

drop policy if exists "auditors+ create documents in own division" on documents;
create policy "auditors+ create documents in own division or dept-wide if supervisor+"
  on documents for insert
  with check (
    (select role from current_profile()) in ('auditor', 'supervisor', 'admin')
    and (
      (select role from current_profile()) = 'admin'
      or division = (select division from current_profile())
    )
    and (
      department_wide = false
      or (select role from current_profile()) in ('supervisor', 'admin')
    )
  );
