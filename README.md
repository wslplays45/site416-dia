# Site-416 — Department of Internal Auditing

## What's new in this update

### Rank system
Replaced the old generic role system (viewer/auditor/supervisor/admin) with direct rank tiers:
`NP (L1) < LR (L2) < MR (L3) < HR (L4) < HICOM (L5)`, plus `Civilian` for non-department bank-only accounts.

- **HICOM** = full admin, sees every division's documents and rosters, no exceptions.
- **HR+** can file documents and add/edit personnel records.
- **MR+ in BAT-OFO** are automatically Banking Staff (can view/edit any account). Admins can also manually grant this to anyone else from Admin → Banking Staff Management.
- **HR+ in CFLT-OFO** can disperse funds into any account, including DIA-IAD's own. *(You only specified the division for this one, not a rank floor — I defaulted to HR+ to match the other sensitive permissions. Easy to loosen if you want any CFLT-OFO rank to have it.)*

### Divisions
`TMT-OFO`, `BAT-OFO`, `CFLT-OFO`, `HSCT-HSS`, `DIA-IAD` (replaces the old "Directorate"), plus `Civilian`.

### Documents
Instead of a single numeric classification level, whoever posts (HR+) can now tick which specific ranks are allowed to see a document (e.g. MR, HR, HICOM — but not LR). Leave all unchecked to make it visible to everyone in scope.

### Banking
- Every account — department or Civilian — still gets a personal bank account automatically.
- **Loans**: anyone can request one from the Banking page; Banking Staff/HICOM approve or deny from Admin. Approval deposits the full amount as a lump sum; repayment is just normal deposits, tracked manually.
- **Department accounts**: any user can create one for a separate site department (e.g. "Site-19 Logistics") — they become the account rep, same as a personal account, just labeled differently.
- **Fund dispersal**: CFLT-OFO (HR+) can push funds into any account by searching for it, same UI pattern as Banking Staff operations.

## Setup — run this migration

In Supabase → SQL Editor, clear the box, paste in the **entire contents** of `supabase/migration_3_ranks_and_expansion.sql`, and run it. This:
- Migrates your existing admin account from Director/Directorate → **HICOM/DIA-IAD** automatically, so you don't lose access.
- Adds constraints locking rank/division to the new fixed sets — anything that doesn't already match gets parked at NP/Civilian so the migration doesn't fail; fix those up afterward from Admin → Personnel Management.
- Adds everything for loans, department accounts, and fund dispersal.

*(This assumes `migration_2_banking.sql` was already run — if setting up completely fresh, run migration 1 (`schema.sql`), then 2, then 3, in that order.)*

Then upload all these files to GitHub as before (overwrite existing ones), and re-enter your real Supabase URL/key into `js/supabase-client.js` on GitHub — it resets to placeholder text in every fresh copy.

## Still to come: the Discord bot
This needs its own conversation once the above is live and tested — specifically your actual Discord role names/IDs mapped to division + rank, and where you want to host a persistent bot process (a VPS, Railway, Replit, etc. — it can't run inside this chat). Ready whenever you are.

## File map
```
index.html          Landing + login
register.html         Invite-code signup
dashboard.html         Overview (balance, recent docs)
personnel.html          Division roster (HR+ can edit)
documents.html          Division + Department-Wide docs, per-rank visibility
banking.html            Accounts, loans, department accounts, staff ops, dispersal
admin.html              Invite codes, personnel management, loan review, audit log
css/styles.css          Design system
js/supabase-client.js   Supabase config + rank-tier permission helpers
supabase/migration_2_banking.sql              Banking system (run first if starting fresh)
supabase/migration_3_ranks_and_expansion.sql  This update (run second)
```
