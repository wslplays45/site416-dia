-- ============================================================
-- SITE-416 :: MIGRATION 3
-- Rank tiers (NP/LR/MR/HR/HICOM), fixed divisions, per-document
-- rank restrictions, loans, department accounts, fund dispersal.
-- Run this in the Supabase SQL Editor.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Backfill existing data BEFORE adding constraints
--    (your current admin account: Director/Directorate -> HICOM/DIA-IAD)
-- ------------------------------------------------------------
update profiles set division = 'DIA-IAD' where division = 'Directorate';
update invite_codes set division = 'DIA-IAD' where division = 'Directorate';

update profiles set rank = 'HICOM' where role = 'admin';
update invite_codes set rank = 'HICOM' where role = 'admin';

-- Anything else that doesn't already match the new rank set gets
-- parked at NP so the constraint below doesn't fail. Adjust these
-- people afterward from Admin > Personnel Management.
update profiles set rank = 'NP'
  where rank not in ('NP','LR','MR','HR','HICOM','Civilian');
update invite_codes set rank = 'NP'
  where rank not in ('NP','LR','MR','HR','HICOM','Civilian');

update profiles set division = 'Civilian'
  where division not in ('TMT-OFO','BAT-OFO','CFLT-OFO','HSCT-HSS','DIA-IAD','Civilian');
update invite_codes set division = 'Civilian'
  where division not in ('TMT-OFO','BAT-OFO','CFLT-OFO','HSCT-HSS','DIA-IAD','Civilian');

update documents set division = 'DIA-IAD' where division = 'Directorate';
update personnel_records set division = 'DIA-IAD' where division = 'Directorate';

-- ------------------------------------------------------------
-- 2. Constraints locking rank/division to fixed sets
-- ------------------------------------------------------------
alter table profiles drop constraint if exists profiles_rank_check;
alter table profiles add constraint profiles_rank_check
  check (rank in ('NP','LR','MR','HR','HICOM','Civilian'));

alter table profiles drop constraint if exists profiles_division_check;
alter table profiles add constraint profiles_division_check
  check (division in ('TMT-OFO','BAT-OFO','CFLT-OFO','HSCT-HSS','DIA-IAD','Civilian'));

alter table invite_codes drop constraint if exists invite_codes_rank_check;
alter table invite_codes add constraint invite_codes_rank_check
  check (rank in ('NP','LR','MR','HR','HICOM','Civilian'));

alter table invite_codes drop constraint if exists invite_codes_division_check;
alter table invite_codes add constraint invite_codes_division_check
  check (division in ('TMT-OFO','BAT-OFO','CFLT-OFO','HSCT-HSS','DIA-IAD','Civilian'));

-- ------------------------------------------------------------
-- 3. Rank tier helper (NP=1 ... HICOM=5) and permission helpers
-- ------------------------------------------------------------
create or replace function rank_tier(p_rank text)
returns int
language sql
immutable
as $$
  select case p_rank
    when 'NP' then 1
    when 'LR' then 2
    when 'MR' then 3
    when 'HR' then 4
    when 'HICOM' then 5
    else 0
  end;
$$;

create or replace function is_hicom(p profiles)
returns boolean
language sql
immutable
as $$
  select p.rank = 'HICOM';
$$;

create or replace function is_banking_or_admin(p profiles)
returns boolean
language sql
immutable
as $$
  select p.rank = 'HICOM'
    or coalesce(p.is_banking_staff, false) = true
    or (rank_tier(p.rank) >= rank_tier('MR') and p.division = 'BAT-OFO');
$$;

create or replace function can_disperse_funds(p profiles)
returns boolean
language sql
immutable
as $$
  select p.rank = 'HICOM'
    or (rank_tier(p.rank) >= rank_tier('HR') and p.division = 'CFLT-OFO');
$$;

-- ------------------------------------------------------------
-- 4. Documents: replace numeric classification with per-rank
--    visibility. allowed_ranks = NULL means "everyone in scope
--    can see it" (still gated by division/department-wide).
-- ------------------------------------------------------------
alter table documents add column if not exists allowed_ranks text[];

drop policy if exists "read documents by division or department-wide, gated by clearance" on documents;
create policy "read documents by division, dept-wide, and rank restriction"
  on documents for select
  using (
    is_hicom(current_profile()) = true
    or (
      (department_wide = true or division = (select division from current_profile()))
      and (
        allowed_ranks is null
        or (select rank from current_profile()) = any(allowed_ranks)
      )
    )
  );

drop policy if exists "auditors+ create documents in own division or dept-wide if supervisor+" on documents;
create policy "HR+ create documents in own division or department-wide"
  on documents for insert
  with check (
    is_hicom(current_profile()) = true
    or (
      rank_tier((select rank from current_profile())) >= rank_tier('HR')
      and division = (select division from current_profile())
    )
  );

drop policy if exists "author or supervisor+ can update document" on documents;
create policy "author or HR+ can update document"
  on documents for update
  using (
    author = auth.uid()
    or is_hicom(current_profile()) = true
    or rank_tier((select rank from current_profile())) >= rank_tier('HR')
  );

-- ------------------------------------------------------------
-- 5. Personnel records: viewing stays division-wide, editing
--    now requires HR+ instead of the old "supervisor" role.
-- ------------------------------------------------------------
drop policy if exists "supervisors+ write personnel in division" on personnel_records;
create policy "HR+ write personnel in division"
  on personnel_records for insert
  with check (
    is_hicom(current_profile()) = true
    or (
      rank_tier((select rank from current_profile())) >= rank_tier('HR')
      and division = (select division from current_profile())
    )
  );

drop policy if exists "supervisors+ update personnel in division" on personnel_records;
create policy "HR+ update personnel in division"
  on personnel_records for update
  using (
    is_hicom(current_profile()) = true
    or (
      rank_tier((select rank from current_profile())) >= rank_tier('HR')
      and division = (select division from current_profile())
    )
  );

-- ------------------------------------------------------------
-- 6. Bank accounts: allow multiple accounts per profile
--    (personal + department accounts), department accounts are
--    rep-owned like personal ones, just tagged differently.
-- ------------------------------------------------------------
alter table bank_accounts add column if not exists account_type text not null default 'personal'
  check (account_type in ('personal', 'department'));
alter table bank_accounts add column if not exists department_name text;

alter table bank_accounts drop constraint if exists bank_accounts_profile_id_key;
drop index if exists bank_accounts_profile_id_key;
create unique index if not exists one_personal_account_per_profile
  on bank_accounts (profile_id) where (account_type = 'personal');

create or replace function create_department_account(p_department_name text)
returns bank_accounts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account bank_accounts;
begin
  if p_department_name is null or trim(p_department_name) = '' then
    raise exception 'Department name is required.';
  end if;

  insert into bank_accounts (profile_id, account_type, department_name)
  values (auth.uid(), 'department', trim(p_department_name))
  returning * into v_account;

  insert into audit_logs (actor, action, target_table, target_id, detail)
  values (auth.uid(), 'banking.department_account_created', 'bank_accounts', v_account.id,
          jsonb_build_object('department_name', p_department_name));

  return v_account;
end;
$$;

grant execute on function create_department_account(text) to authenticated;

-- ------------------------------------------------------------
-- 7. Update banking functions to use is_banking_or_admin()
--    instead of the raw is_banking_staff flag
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
  if is_banking_or_admin(v_caller) = false then
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
  if is_banking_or_admin(v_caller) = false then
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
  if is_banking_or_admin(v_caller) = false then
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

drop function if exists bank_search_accounts(text);
create or replace function bank_search_accounts(p_query text default '')
returns table (
  account_id uuid,
  profile_id uuid,
  full_name text,
  callsign text,
  division text,
  rank text,
  account_type text,
  department_name text,
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
  if is_banking_or_admin(v_caller) = false and can_disperse_funds(v_caller) = false then
    raise exception 'Not authorized.';
  end if;

  return query
  select a.id, p.id, p.full_name, p.callsign, p.division, p.rank, a.account_type, a.department_name, a.balance
  from bank_accounts a
  join profiles p on p.id = a.profile_id
  where p.full_name ilike '%' || p_query || '%'
     or p.callsign ilike '%' || p_query || '%'
     or a.department_name ilike '%' || p_query || '%'
  order by p.full_name
  limit 25;
end;
$$;

-- ------------------------------------------------------------
-- 7b. Fix bank_accounts/bank_transactions SELECT policies —
--     these still only checked the raw is_banking_staff flag,
--     not the automatic MR+/BAT-OFO rule computed above.
-- ------------------------------------------------------------
drop policy if exists "own account or banking staff/admin read accounts" on bank_accounts;
create policy "own account or banking staff/admin read accounts"
  on bank_accounts for select
  using (
    profile_id = auth.uid()
    or is_banking_or_admin(current_profile()) = true
  );

drop policy if exists "own transactions or banking staff/admin read transactions" on bank_transactions;
create policy "own transactions or banking staff/admin read transactions"
  on bank_transactions for select
  using (
    exists (select 1 from bank_accounts a where a.id = bank_transactions.account_id and a.profile_id = auth.uid())
    or is_banking_or_admin(current_profile()) = true
  );

-- ------------------------------------------------------------
-- 8. Fund dispersal (CFLT-OFO, HR+) into any account
-- ------------------------------------------------------------
create or replace function disburse_funds(p_account_id uuid, p_amount numeric, p_note text default null)
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
  if can_disperse_funds(v_caller) = false then
    raise exception 'Not authorized to disperse funds.';
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
  values (p_account_id, 'deposit', p_amount, v_account.balance, v_caller.id,
          coalesce('[DISBURSEMENT] ' || p_note, '[DISBURSEMENT]'));

  return v_account;
end;
$$;

grant execute on function disburse_funds(uuid, numeric, text) to authenticated;

-- ------------------------------------------------------------
-- 9. Loans (simple: request -> approve/deny -> lump-sum deposit;
--    repayment tracked manually via normal deposits)
-- ------------------------------------------------------------
do $$ begin
  create type loan_status as enum ('pending', 'approved', 'denied');
exception
  when duplicate_object then null;
end $$;

create table if not exists loan_requests (
  id uuid primary key default uuid_generate_v4(),
  account_id uuid not null references bank_accounts(id) on delete cascade,
  requested_by uuid not null references profiles(id),
  amount numeric(12,2) not null check (amount > 0),
  reason text,
  status loan_status not null default 'pending',
  reviewed_by uuid references profiles(id),
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now()
);

alter table loan_requests enable row level security;

drop policy if exists "own loans or banking staff/admin read loans" on loan_requests;
create policy "own loans or banking staff/admin read loans"
  on loan_requests for select
  using (
    requested_by = auth.uid()
    or is_banking_or_admin(current_profile()) = true
  );

create or replace function request_loan(p_amount numeric, p_reason text default null)
returns loan_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account bank_accounts;
  v_loan loan_requests;
begin
  if p_amount <= 0 then
    raise exception 'Amount must be positive.';
  end if;

  select * into v_account from bank_accounts
    where profile_id = auth.uid() and account_type = 'personal';

  if v_account is null then
    raise exception 'No personal account found.';
  end if;

  insert into loan_requests (account_id, requested_by, amount, reason)
  values (v_account.id, auth.uid(), p_amount, p_reason)
  returning * into v_loan;

  return v_loan;
end;
$$;

create or replace function review_loan(p_loan_id uuid, p_approve boolean, p_note text default null)
returns loan_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller profiles;
  v_loan loan_requests;
  v_account bank_accounts;
begin
  select * into v_caller from current_profile();
  if is_banking_or_admin(v_caller) = false then
    raise exception 'Not authorized to review loans.';
  end if;

  select * into v_loan from loan_requests where id = p_loan_id for update;
  if v_loan is null then
    raise exception 'Loan request not found.';
  end if;
  if v_loan.status != 'pending' then
    raise exception 'This loan request has already been reviewed.';
  end if;

  update loan_requests
    set status = case when p_approve then 'approved' else 'denied' end,
        reviewed_by = v_caller.id,
        reviewed_at = now(),
        review_note = p_note
    where id = p_loan_id
    returning * into v_loan;

  if p_approve then
    update bank_accounts set balance = balance + v_loan.amount
      where id = v_loan.account_id
      returning * into v_account;

    insert into bank_transactions (account_id, type, amount, balance_after, performed_by, note)
    values (v_loan.account_id, 'deposit', v_loan.amount, v_account.balance, v_caller.id,
            coalesce('[LOAN APPROVED] ' || v_loan.reason, '[LOAN APPROVED]'));
  end if;

  return v_loan;
end;
$$;

grant execute on function request_loan(numeric, text) to authenticated;
grant execute on function review_loan(uuid, boolean, text) to authenticated;

-- ------------------------------------------------------------
-- 10. Admin: edit an existing profile's rank/division
-- ------------------------------------------------------------
create or replace function admin_update_profile(p_profile_id uuid, p_rank text, p_division text)
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
  if v_caller.rank != 'HICOM' and v_caller.role != 'admin' then
    raise exception 'Only HICOM can edit personnel rank/division.';
  end if;

  update profiles
    set rank = p_rank,
        division = p_division,
        clearance_level = rank_tier(p_rank),
        role = case when p_rank = 'HICOM' then 'admin' else 'viewer' end
    where id = p_profile_id
    returning * into v_profile;

  return v_profile;
end;
$$;

grant execute on function admin_update_profile(uuid, text, text) to authenticated;

-- ------------------------------------------------------------
-- 11. Update redeem_invite_code() to sync role from rank
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
  v_role access_role;
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

  v_role := case when v_invite.rank = 'HICOM' then 'admin'::access_role else 'viewer'::access_role end;

  insert into profiles (id, full_name, callsign, division, rank, role, clearance_level, is_banking_staff)
  values (auth.uid(), p_full_name, p_callsign, v_invite.division, v_invite.rank, v_role, rank_tier(v_invite.rank), v_invite.is_banking_staff)
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
