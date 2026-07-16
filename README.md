# Site-416 — Department of Internal Auditing

## What's new in this update
- **Banking system**: every account (department staff or civilian) automatically gets a bank account on signup. Balances and full transaction history (deposits, withdrawals, transfers) are tracked. Only users flagged as "Banking Staff" (or admins) can view/edit accounts other than their own — granted via invite code or toggled on an existing user from the Admin panel.
- **Department-wide documents**: the Documents page now has two tabs — "My Division" (locked to your division, existing behavior) and "Department-Wide" (visible to everyone, still gated by classification level). Only supervisors/admins can post department-wide.
- All money movement goes through server-side functions (`bank_deposit`, `bank_withdraw`, `bank_transfer`) — balances can never be edited directly from the browser, only logged, audited transactions.

## Setup — 2 steps

### 1. Run the migration
In Supabase → SQL Editor, paste in the full contents of `supabase/migration_2_banking.sql` and run it. This only *adds* things — your existing tables, users, and data are untouched.

### 2. Upload the frontend
Upload every file in this folder to your GitHub repo, overwriting the existing ones (same as before — GitHub will offer to replace files with matching paths).

**Important:** after uploading, edit `js/supabase-client.js` on GitHub one more time and put your real Supabase URL and anon key back in — they reset to placeholders in this fresh copy:
```js
const SUPABASE_URL = "https://YOUR-PROJECT-REF.supabase.co";
const SUPABASE_ANON_KEY = "YOUR-ANON-PUBLIC-KEY";
```

## How civilians get accounts
Generate an invite code from the Admin panel using something like "Civilian" for both Division and Rank, with the Viewer role. They register with it just like department staff — and get a bank account automatically, same as everyone else.

## How to make someone Banking Staff
Two ways:
- Check "Grant Banking Staff access" when generating their invite code (for new accounts)
- Or, in Admin → Banking Staff Management, search for an existing person and click Grant/Revoke

## File map
```
index.html          Landing + login
register.html         Invite-code signup
dashboard.html         Role-aware overview (now shows balance too)
personnel.html          Division roster
documents.html          Division docs + Department-Wide tab
banking.html            Own account view + banking staff operations (NEW)
admin.html              Invite codes, banking staff management, audit log
css/styles.css          Design system
js/supabase-client.js   Supabase config + shared helpers
supabase/migration_2_banking.sql   Run this once to add banking + dept-wide docs
```
