// ============================================================
// SITE-416 :: Supabase client
// Fill these in from Project Settings > API in your Supabase
// dashboard. The anon/public key is safe to expose in a static
// frontend — Row Level Security in schema.sql does the real
// enforcement server-side.
//
// NOTE: the client is named "supabaseClient" (not "supabase")
// on purpose — the CDN script tag above already creates a
// global called "supabase", so reusing that name causes a
// "already been declared" error in the browser.
// ============================================================

const SUPABASE_URL = "https://YOUR-PROJECT-REF.supabase.co";
const SUPABASE_ANON_KEY = "YOUR-ANON-PUBLIC-KEY";

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// ------------------------------------------------------------
// Shared helpers used across pages
// ------------------------------------------------------------

async function requireSession() {
  const { data: { session } } = await supabaseClient.auth.getSession();
  if (!session) {
    window.location.href = "index.html";
    return null;
  }
  return session;
}

async function getCurrentProfile() {
  const { data: { user } } = await supabaseClient.auth.getUser();
  if (!user) return null;
  const { data, error } = await supabaseClient
    .from("profiles")
    .select("*")
    .eq("id", user.id)
    .single();
  if (error) {
    console.error("Failed to load profile:", error);
    return null;
  }
  return data;
}

async function logAction(action, targetTable = null, targetId = null, detail = {}) {
  const { data: { user } } = await supabaseClient.auth.getUser();
  if (!user) return;
  await supabaseClient.from("audit_logs").insert({
    actor: user.id,
    action,
    target_table: targetTable,
    target_id: targetId,
    detail
  });
}

async function signOut() {
  await supabaseClient.auth.signOut();
  window.location.href = "index.html";
}

function roleRank(role) {
  return { viewer: 0, auditor: 1, supervisor: 2, admin: 3 }[role] ?? 0;
}

function renderStamp(profile) {
  if (!profile) return "";
  return `<span class="stamp role-${profile.role}"><span class="stamp-dot"></span>${profile.rank} · ${profile.division}</span>`;
}
