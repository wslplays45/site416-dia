# Site-416 — Department of Internal Auditing

## Status
- Database schema: already applied to your Supabase project ✅
- Frontend: fixed — the client variable was renamed from `supabase` to
  `supabaseClient` throughout, because the Supabase CDN script already
  creates a global called `supabase`; declaring another one with the
  same name caused the "already been declared" error you were seeing.

## What to do with this folder
Upload these files to your GitHub repo, **overwriting the existing ones**
(drag them into the repo's file list — GitHub will ask to replace files
with the same name/path).

**Important:** after uploading, edit `js/supabase-client.js` **directly on
GitHub** (pencil icon → edit) one more time and put your real Supabase
Project URL and anon key back into these two lines — they're placeholders
again in this fresh copy:

```js
const SUPABASE_URL = "https://YOUR-PROJECT-REF.supabase.co";
const SUPABASE_ANON_KEY = "YOUR-ANON-PUBLIC-KEY";
```

## File map
```
index.html          Landing + login
register.html        Invite-code signup
dashboard.html        Role-aware overview
personnel.html         Division roster
documents.html         Reports/findings
admin.html             Invite codes + audit log (admin only)
css/styles.css         Design system
js/supabase-client.js  Supabase config + shared helpers
supabase/schema.sql     Reference copy of the DB schema (already applied)
```
