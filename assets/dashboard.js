const MATCH_ENTRY_FEE = 50;

const loadingEl = document.getElementById("loading");
const dashEl = document.getElementById("dashboard");
const avatarEl = document.getElementById("avatar");
const nameEl = document.getElementById("player-name");
const balanceEl = document.getElementById("balance-value");
const logoutBtn = document.getElementById("logout-btn");
const matchOverlay = document.getElementById("match-overlay");
const cancelMatchBtn = document.getElementById("cancel-match-btn");
const matchTitle = document.getElementById("match-title");
const matchStatus = document.getElementById("match-status");
const playButtons = document.querySelectorAll(".play-btn");

let currentBalance = 0;

async function init() {
  try {
    const { data: { session }, error: sessionError } = await client.auth.getSession();

    if (sessionError || !session) {
      window.location.href = "index.html";
      return;
    }

    const user = session.user;
    const meta = user.user_metadata || {};

    // 1. Populate user name and avatar
    if (nameEl) {
      nameEl.textContent = meta.full_name || meta.name || user.email?.split("@")[0] || "Player";
    }

    if (avatarEl && (meta.avatar_url || meta.picture)) {
      avatarEl.src = meta.avatar_url || meta.picture;
    }

    // 2. Fetch live wallet token balance
    const { data: wallet, error: walletError } = await client
      .from("wallet")
      .select("dummy_token")
      .eq("user_id", user.id)
      .single();

    currentBalance = walletError || !wallet ? 0 : wallet.dummy_token;

    if (balanceEl) {
      balanceEl.textContent = currentBalance.toLocaleString();
    }

    // 3. Display the dashboard interface
    if (loadingEl) loadingEl.classList.add("hidden");
    if (dashEl) dashEl.classList.remove("hidden");

  } catch (err) {
    console.error("Dashboard error:", err);
    if (loadingEl) {
      loadingEl.innerHTML = `<p style="color: #ef4444;">Failed to load arena data. <a href="index.html" style="color:#00e701;">Sign in again</a></p>`;
    }
  }
}

// 4. Handle game card clicks
playButtons.forEach((btn) => {
  btn.addEventListener("click", () => {
    const gameName = btn.getAttribute("data-game") || "Match";

    if (currentBalance < MATCH_ENTRY_FEE) {
      alert(`You need at least ${MATCH_ENTRY_FEE} tokens to enter. Current balance: ${currentBalance}`);
      return;
    }

    if (matchTitle) matchTitle.textContent = `Finding Opponent for ${gameName}`;
    if (matchStatus) matchStatus.textContent = "Connecting to queue with real players...";
    if (matchOverlay) matchOverlay.classList.remove("hidden");
  });
});

// 5. Cancel matchmaking
if (cancelMatchBtn) {
  cancelMatchBtn.addEventListener("click", () => {
    if (matchOverlay) matchOverlay.classList.add("hidden");
  });
}

// 6. Sign out
if (logoutBtn) {
  logoutBtn.addEventListener("click", async () => {
    await client.auth.signOut();
    window.location.href = "index.html";
  });
}

init();
