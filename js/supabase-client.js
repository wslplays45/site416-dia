// ============================================================
// SITE-416 :: Supabase client
// Fill these in from Project Settings > API in your Supabase
// dashboard.
// ============================================================

const SUPABASE_URL = "https://ikfphgluykkvoatdoafj.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlrZnBoZ2x1eWtrdm9hdGRvYWZqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQwODAzOTUsImV4cCI6MjA5OTY1NjM5NX0.fs2zG7y5ub2xiyu8xb34lQfR2gvzVAetGEt0s2RmGUU";

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

const RANK_TIERS = { LR: 2, MR: 3, HR: 4, HICOM: 5, Civilian: 0 };
const DIVISIONS = ["TMT-OFO", "BAT-OFO", "CFLT-OFO", "HSCT-HSS", "DIA-IAD"];
const RANKS = ["LR", "MR", "HR", "HICOM"];

function rankTier(rank) {
  return RANK_TIERS[rank] ?? 0;
}

function isHicom(profile) {
  return profile?.rank === "HICOM";
}

function canPostDocuments(profile) {
  return isHicom(profile) || rankTier(profile?.rank) >= rankTier("HR");
}

function canEditPersonnel(profile) {
  return isHicom(profile) || rankTier(profile?.rank) >= rankTier("HR");
}

function isBankingOrAdmin(profile) {
  return isHicom(profile)
    || !!profile?.is_banking_staff
    || (rankTier(profile?.rank) >= rankTier("MR") && profile?.division === "BAT-OFO");
}

function canDisperseFunds(profile) {
  return isHicom(profile)
    || (rankTier(profile?.rank) >= rankTier("HR") && profile?.division === "CFLT-OFO");
}

function renderStamp(profile) {
  if (!profile) return "";
  const stampClass = isHicom(profile) ? "role-admin" : rankTier(profile.rank) >= rankTier("HR") ? "role-supervisor" : rankTier(profile.rank) >= rankTier("MR") ? "role-auditor" : "role-viewer";
  return `<span class="stamp ${stampClass}"><span class="stamp-dot"></span>${profile.rank} · ${profile.division}</span>`;
}

function rankOptionsHtml(selected = "") {
  return RANKS.map(r => `<option value="${r}" ${r === selected ? "selected" : ""}>${r}</option>`).join("")
    + `<option value="Civilian" ${selected === "Civilian" ? "selected" : ""}>Civilian</option>`;
}

function divisionOptionsHtml(selected = "") {
  return DIVISIONS.map(d => `<option value="${d}" ${d === selected ? "selected" : ""}>${d}</option>`).join("")
    + `<option value="Civilian" ${selected === "Civilian" ? "selected" : ""}>Civilian</option>`;
}

function formatCurrency(amount) {
  const n = Number(amount);
  return n.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str ?? "";
  return div.innerHTML;
}
