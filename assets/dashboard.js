const loadingEl = document.getElementById("loading");
const dashEl = document.getElementById("dashboard");
const avatarEl = document.getElementById("avatar");
const nameEl = document.getElementById("player-name");
const balanceEl = document.getElementById("balance-value");
const logoutBtn = document.getElementById("logout-btn");
const overlay = document.getElementById("matchmaking-overlay");
const statusEl = document.getElementById("matchmaking-status");
const cancelBtn = document.getElementById("cancel-matchmaking");

let currentUserId = null;

async function init() {
  const { data: { session } } = await client.auth.getSession();

  if (!session) {
    window.location.href = "index.html";
    return;
  }

  currentUserId = session.user.id;
  const meta = session.user.user_metadata || {};

  nameEl.textContent = meta.full_name || meta.name || session.user.email;
  if (meta.avatar_url || meta.picture) {
    avatarEl.src = meta.avatar_url || meta.picture;
  }

  await refreshBalance();

  loadingEl.classList.add("hidden");
  dashEl.classList.remove("hidden");
}

async function refreshBalance() {
  const { data: wallet, error } = await client
    .from("wallet")
    .select("dummy_token")
    .eq("user_id", currentUserId)
    .single();

  const balance = error || !wallet ? 0 : wallet.dummy_token;
  balanceEl.textContent = balance.toLocaleString();
  return balance;
}

document.querySelectorAll(".game-card").forEach((card) => {
  card.addEventListener("click", async () => {
    const gameType = card.dataset.game;
    const balance = await refreshBalance();

    if (balance < 50) {
      alert("You need at least 50 tokens to play. Come back once you've earned more!");
      return;
    }

    overlay.classList.remove("hidden");
    statusEl.textContent = "Deducting entry fee...";

    startMatchmaking(gameType, currentUserId, (status) => {
      if (status === "insufficient") {
        overlay.classList.add("hidden");
        alert("Insufficient tokens.");
        return;
      }
      statusEl.textContent = status;
    });
  });
});

cancelBtn.addEventListener("click", async () => {
  await cancelMatchmaking(currentUserId);
  overlay.classList.add("hidden");
  await refreshBalance();
});

logoutBtn.addEventListener("click", async () => {
  await client.auth.signOut();
  window.location.href = "index.html";
});

init();
