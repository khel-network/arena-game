const MATCH_ENTRY_FEE = 50;
const loadingEl = document.getElementById("loading");
const dashEl = document.getElementById("dashboard");
const avatarEl = document.getElementById("avatar");
const nameEl = document.getElementById("player-name");
const balanceEl = document.getElementById("balance-value");
const matchBtn = document.getElementById("match-btn");
const logoutBtn = document.getElementById("logout-btn");

async function init() {
  const { data: { session } } = await client.auth.getSession();
  if (!session) { window.location.href = "index.html"; return; }

  const user = session.user;
  const meta = user.user_metadata || {};
  nameEl.textContent = meta.full_name || meta.name || user.email;
  if (meta.avatar_url || meta.picture) avatarEl.src = meta.avatar_url || meta.picture;

  const { data: wallet, error } = await client
    .from("wallet").select("dummy_token").eq("user_id", user.id).single();

  const balance = error || !wallet ? 0 : wallet.dummy_token;
  balanceEl.textContent = balance.toLocaleString();

  if (balance < MATCH_ENTRY_FEE) {
    matchBtn.disabled = true;
    matchBtn.textContent = "Insufficient tokens";
  } else {
    matchBtn.textContent = `Join Match (-${MATCH_ENTRY_FEE} tokens)`;
  }
  loadingEl.classList.add("hidden");
  dashEl.classList.remove("hidden");
}

matchBtn.addEventListener("click", () => {
  matchBtn.disabled = true;
  matchBtn.textContent = "Searching for opponent...";
  // TODO: call a Supabase Edge Function here to atomically deduct
  // MATCH_ENTRY_FEE and pair with a real queued player — never a bot.
});

logoutBtn.addEventListener("click", async () => {
  await client.auth.signOut();
  window.location.href = "index.html";
});

init();
