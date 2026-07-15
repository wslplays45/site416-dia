# Site-416 — Department of Internal Auditing

Internal portal: invite-code signup, automatic division/rank/role assignment, personnel roster, documents, audit log.

## 1. Set up Supabase (backend)

1. Create a free project at [supabase.com](https://supabase.com).
2. Go to **SQL Editor** → paste in the full contents of `supabase/schema.sql` → Run.
   - This creates all tables, the `redeem_invite_code()` function, and RLS policies.
   - It also seeds one bootstrap admin invite code: `SITE416-ROOT-ADMIN-0001`. **Change this code before running**, or rotate/delete it immediately after your first admin account is created.
3. Go to **Authentication → Settings** and, for local testing, consider disabling "Confirm email" so signup works immediately. For production, leave email confirmation on — just note that `redeem_invite_code()` needs an active session, so if confirmation is required, call it right after the user's first login rather than immediately after signup (there's a comment marking this in `register.html`).
4. Go to **Project Settings → API** and copy your **Project URL** and **anon public key**.

## 2. Connect the frontend

Open `js/supabase-client.js` and replace:

```js
const SUPABASE_URL = "https://YOUR-PROJECT-REF.supabase.co";
const SUPABASE_ANON_KEY = "YOUR-ANON-PUBLIC-KEY";
```

with your real values. The anon key is safe to expose publicly — Row Level Security in `schema.sql` is what actually enforces permissions.

## 3. Bootstrap your admin account

1. Open `register.html` locally (or after deploying) and register using the seed code from step 1.
2. This gives you an `admin` role account. From here, use the **Admin** tab to generate real invite codes for every division/rank you need — delete or rotate the seed code once you're in.

## 4. Deploy to GitHub Pages

1. Push this folder to a GitHub repo.
2. Repo → **Settings → Pages** → set source to your main branch (root).
3. Your site will be live at `https://yourusername.github.io/reponame/`.

## File map

```
index.html        Landing + login
register.html      Invite-code signup
dashboard.html      Role-aware overview
personnel.html      Division roster (supervisor+ can add records)
documents.html      Reports/findings (auditor+ can file, clearance-gated reads)
admin.html          Invite code generation + audit log (admin only)
css/styles.css      Design system (black / white / purple)
js/supabase-client.js  Supabase config + shared helpers
supabase/schema.sql     Full DB schema + RLS policies
```

## Roles & permissions (enforced server-side via RLS)

| Role | Can do |
|---|---|
| `viewer` | Read documents in their division up to their clearance level |
| `auditor` | + File new documents |
| `supervisor` | + Add/edit personnel records, read profiles in their division |
| `admin` | Full access across all divisions, generate invite codes, view audit log |

## Extending it

- Add more divisions/ranks freely — they're just text fields on the invite code, not hardcoded enums.
- To add a new page, copy the `<script>` block pattern in `dashboard.html`: call `requireSession()`, then `getCurrentProfile()`, then query Supabase directly — RLS will silently scope results to what that user is allowed to see.
- `logAction()` in `supabase-client.js` writes to `audit_logs` — call it after any write you want tracked.
