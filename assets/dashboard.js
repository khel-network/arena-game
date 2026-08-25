const MATCH_ENTRY_FEE = 50;
const MATCH_WIN_REWARD = 90;

// Indian Names Pool for Fallback
const INDIAN_BOT_POOL = [
  { name: "Aarav_Sharma", seed: "aarav" },
  { name: "Priya_Patel", seed: "priya" },
  { name: "Rohan_Verma", seed: "rohan" },
  { name: "Ananya_Singh", seed: "ananya" },
  { name: "Vikram_Malhotra", seed: "vikram" },
  { name: "Sneha_Reddy", seed: "sneha" },
  { name: "Aditya_Kumar", seed: "aditya" },
  { name: "Neha_Gupta", seed: "neha" },
  { name: "Karan_Mehta", seed: "karan" },
  { name: "Divya_Roy", seed: "divya" },
  { name: "Arjun_Chopra", seed: "arjun" },
  { name: "Riya_Sen", seed: "riya" }
];

// App State
let currentUser = null;
let currentBalance = 1000;
let matchHistory = [];
let transactions = [];
let activeOpponent = null;
let activeGame = null;
let matchmakingTimer = null;
let walletChannel = null;
let currentFlowIsReal = false;

const REAL_MULTIPLAYER_GAMES = ["reaction", "tictactoe", "quiz", "math"];

// ----------------------------------------------------
// Currency helper - all amounts are shown in Indian Rupees
// ----------------------------------------------------
function formatINR(amount) {
  const n = Number(amount) || 0;
  return "\u20b9" + n.toLocaleString("en-IN");
}

// DOM Elements
const loadingEl = document.getElementById("loading");
const dashEl = document.getElementById("dashboard");
const balanceEl = document.getElementById("balance-value");
const playerNameEl = document.getElementById("player-name");
const avatarEl = document.getElementById("avatar");
const logoutBtn = document.getElementById("logout-btn");

// Profile View Elements
const profileDisplayName = document.getElementById("profile-display-name");
const profileViewAvatar = document.getElementById("profile-view-avatar");
const editNameBtn = document.getElementById("edit-name-btn");
const nameEditBox = document.getElementById("name-edit-box");
const nameInput = document.getElementById("name-input");
const saveNameBtn = document.getElementById("save-name-btn");
const cancelNameBtn = document.getElementById("cancel-name-btn");

// Navigation & Category Elements
const tabButtons = document.querySelectorAll(".tab-btn");
const appViews = document.querySelectorAll(".app-view");
const filterChips = document.querySelectorAll(".filter-chip");
const gameCards = document.querySelectorAll(".game-card");
const playButtons = document.querySelectorAll(".play-btn");

// Matchmaking & Arena Overlays
const matchOverlay = document.getElementById("match-overlay");
const cancelMatchBtn = document.getElementById("cancel-match-btn");
const matchTitle = document.getElementById("match-title");
const matchStatus = document.getElementById("match-status");

const arenaOverlay = document.getElementById("game-arena-overlay");
const arenaUserAvatar = document.getElementById("arena-user-avatar");
const arenaUserName = document.getElementById("arena-user-name");
const arenaOppAvatar = document.getElementById("arena-opp-avatar");
const arenaOppName = document.getElementById("arena-opp-name");
const arenaStage = document.getElementById("arena-stage");

// ----------------------------------------------------
// 1. Initialization
// ----------------------------------------------------
async function init() {
  try {
    const sessionRes = await client.auth.getSession();
    const session = sessionRes && sessionRes.data ? sessionRes.data.session : null;

    if (!session) {
      window.location.href = "index.html";
      return;
    }

    currentUser = session.user;
    loadLocalUserData();
    await refreshWalletFromServer();
    subscribeWalletRealtime();
    updateUI();
  } catch (err) {
    console.error("Initialization error:", err);
  } finally {
    // Guaranteed dismissal of loading screen
    if (loadingEl) loadingEl.classList.add("hidden");
    if (dashEl) dashEl.classList.remove("hidden");
  }
}

// 3-second absolute safety fallback
setTimeout(() => {
  if (loadingEl && !loadingEl.classList.contains("hidden")) {
    loadingEl.classList.add("hidden");
    if (dashEl) dashEl.classList.remove("hidden");
  }
}, 3000);

function loadLocalUserData() {
  const savedName = localStorage.getItem("arena_name_" + currentUser.id);
  const meta = currentUser.user_metadata || {};
  const initialName = savedName || meta.full_name || meta.name || (currentUser.email ? currentUser.email.split("@")[0] : "Player");

  const storedTx = localStorage.getItem("arena_tx_" + currentUser.id);
  if (storedTx) {
    try {
      transactions = JSON.parse(storedTx);
    } catch (e) {
      transactions = [];
    }
  } else {
    transactions = [
      { desc: "Welcome Bonus Credited", type: "credit", amount: 1000, date: new Date().toLocaleString() }
    ];
    saveTransactions();
  }

  const storedMatches = localStorage.getItem("arena_matches_" + currentUser.id);
  if (storedMatches) {
    try {
      matchHistory = JSON.parse(storedMatches);
    } catch (e) {
      matchHistory = [];
    }
  }

  setUserDisplayName(initialName);
}

function setUserDisplayName(name) {
  if (playerNameEl) playerNameEl.textContent = name;
  if (profileDisplayName) profileDisplayName.textContent = name;
  const avatarUrl = "https://api.dicebear.com/7.x/identicon/svg?seed=" + encodeURIComponent(name);
  if (avatarEl) avatarEl.src = avatarUrl;
  if (profileViewAvatar) profileViewAvatar.src = avatarUrl;
}

// ----------------------------------------------------
// Live wallet sync — keeps the balance accurate across tabs,
// devices, and re-logins to the same account instead of
// relying on a stale local number.
// ----------------------------------------------------
async function refreshWalletFromServer() {
  if (!currentUser) return;
  try {
    const { data: wallet, error } = await client
      .from("wallet")
      .select("dummy_token")
      .eq("user_id", currentUser.id)
      .single();
    if (!error && wallet && typeof wallet.dummy_token === "number") {
      if (wallet.dummy_token !== currentBalance) {
        currentBalance = wallet.dummy_token;
        updateUI();
        flashBalance();
      }
    }
  } catch (e) {
    console.warn("Wallet refresh fallback to local balance:", e);
  }
}

function subscribeWalletRealtime() {
  if (!currentUser || typeof client === "undefined") return;
  if (walletChannel) {
    client.removeChannel(walletChannel);
  }
  walletChannel = client
    .channel("wallet-live-" + currentUser.id)
    .on(
      "postgres_changes",
      {
        event: "UPDATE",
        schema: "public",
        table: "wallet",
        filter: `user_id=eq.${currentUser.id}`,
      },
      (payload) => {
        if (payload.new && typeof payload.new.dummy_token === "number" && payload.new.dummy_token !== currentBalance) {
          currentBalance = payload.new.dummy_token;
          updateUI();
          flashBalance();
        }
      }
    )
    .subscribe();
}

// Re-sync whenever the tab regains focus/visibility, or the same
// browser session signs back in — covers cases where a realtime
// event was missed while the tab was backgrounded.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") refreshWalletFromServer();
});
window.addEventListener("focus", refreshWalletFromServer);

if (typeof client !== "undefined" && client.auth) {
  client.auth.onAuthStateChange((event, session) => {
    if (event === "SIGNED_OUT") {
      window.location.href = "index.html";
      return;
    }
    if (event === "SIGNED_IN" && session && session.user) {
      currentUser = session.user;
      refreshWalletFromServer();
      subscribeWalletRealtime();
    }
  });
}

async function writeWalletBalance(newBalance) {
  currentBalance = newBalance;
  if (!currentUser) return;
  try {
    await client
      .from("wallet")
      .update({ dummy_token: newBalance, updated_at: new Date().toISOString() })
      .eq("user_id", currentUser.id);
  } catch (e) {
    console.warn("Wallet write failed, will resync on next refresh:", e);
  }
}

function flashBalance() {
  [balanceEl, document.getElementById("stat-total-earnings")].forEach((el) => {
    if (!el) return;
    el.classList.remove("balance-flash");
    // force reflow so the animation can retrigger
    void el.offsetWidth;
    el.classList.add("balance-flash");
  });
}

function updateUI() {
  if (balanceEl) balanceEl.textContent = currentBalance.toLocaleString("en-IN");

  const progressPercent = Math.min(100, Math.round((currentBalance / 2500) * 100));
  const progressFill = document.getElementById("progress-fill");
  const progressText = document.getElementById("progress-text");
  if (progressFill) progressFill.style.width = progressPercent + "%";
  if (progressText) {
    progressText.textContent = formatINR(currentBalance) + " / " + formatINR(2500) + " towards cashout";
  }

  const totalMatches = matchHistory.length;
  const wins = matchHistory.filter(m => m.result === "VICTORY").length;
  const winRate = totalMatches > 0 ? Math.round((wins / totalMatches) * 100) : 0;
  const totalWonTokens = wins * MATCH_WIN_REWARD;

  const statEarnings = document.getElementById("stat-total-earnings");
  const statMatches = document.getElementById("stat-matches-played");
  const statRate = document.getElementById("stat-win-rate");
  const statWon = document.getElementById("stat-tokens-won");

  if (statEarnings) statEarnings.textContent = formatINR(currentBalance);
  if (statMatches) statMatches.textContent = totalMatches;
  if (statRate) statRate.textContent = winRate + "%";
  if (statWon) statWon.textContent = "+" + formatINR(totalWonTokens);

  renderLedger();
  renderMatchHistory();
}

function renderLedger() {
  const tbody = document.getElementById("ledger-body");
  if (!tbody) return;
  if (transactions.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4" style="text-align:center; color:var(--text-dim);">No transactions recorded</td></tr>';
    return;
  }
  tbody.innerHTML = transactions.map(tx => {
    const isCredit = tx.type === "credit";
    const sign = isCredit ? "+" : "-";
    const color = isCredit ? "var(--primary-green)" : "var(--accent-red)";
    const badgeClass = isCredit ? "badge-credit" : "badge-debit";
    return '<tr>' +
      '<td>' + tx.desc + '</td>' +
      '<td><span class="' + badgeClass + '">' + tx.type.toUpperCase() + '</span></td>' +
      '<td style="font-weight:700; color:' + color + ';">' + sign + formatINR(tx.amount) + '</td>' +
      '<td style="color:var(--text-dim);">' + tx.date + '</td>' +
    '</tr>';
  }).join("");
}

function renderMatchHistory() {
  const tbody = document.getElementById("matches-body");
  if (!tbody) return;
  if (matchHistory.length === 0) {
    tbody.innerHTML = '<tr><td colspan="5" style="text-align:center; color:var(--text-dim);">No matches played yet. Choose a game above!</td></tr>';
    return;
  }
  tbody.innerHTML = matchHistory.map(m => {
    const isWin = m.result === "VICTORY";
    const color = isWin ? "var(--primary-green)" : "var(--accent-red)";
    const badgeClass = isWin ? "badge-credit" : "badge-debit";
    return '<tr>' +
      '<td style="font-weight:600;">' + m.game + '</td>' +
      '<td>' + m.opponent + '</td>' +
      '<td><span class="' + badgeClass + '">' + m.result + '</span></td>' +
      '<td style="font-weight:700; color:' + color + ';">' + m.reward + '</td>' +
      '<td style="color:var(--text-dim);">' + m.date + '</td>' +
    '</tr>';
  }).join("");
}

function recordTransaction(desc, type, amount) {
  transactions.unshift({ desc: desc, type: type, amount: amount, date: new Date().toLocaleString() });
  saveTransactions();
  updateUI();
  flashBalance();
}

function saveTransactions() {
  if (currentUser) {
    localStorage.setItem("arena_tx_" + currentUser.id, JSON.stringify(transactions.slice(0, 50)));
  }
}

function saveMatches() {
  if (currentUser) {
    localStorage.setItem("arena_matches_" + currentUser.id, JSON.stringify(matchHistory.slice(0, 50)));
  }
}

// ----------------------------------------------------
// 2. Navigation & Category Filters
// ----------------------------------------------------
function switchView(targetId) {
  tabButtons.forEach(b => b.classList.remove("active"));
  appViews.forEach(v => v.classList.remove("active"));

  document.querySelectorAll('.tab-btn[data-target="' + targetId + '"]').forEach(b => b.classList.add("active"));

  const targetView = document.getElementById(targetId);
  if (targetView) targetView.classList.add("active");
}

tabButtons.forEach(btn => {
  btn.addEventListener("click", () => switchView(btn.getAttribute("data-target")));
});

document.getElementById("profile-nav-btn")?.addEventListener("click", () => switchView("view-profile"));
document.getElementById("nav-brand-logo")?.addEventListener("click", () => switchView("view-earn"));

filterChips.forEach(chip => {
  chip.addEventListener("click", () => {
    filterChips.forEach(c => c.classList.remove("active"));
    chip.classList.add("active");

    const category = chip.getAttribute("data-category");

    gameCards.forEach(card => {
      if (category === "all" || card.getAttribute("data-category") === category) {
        card.style.display = "flex";
      } else {
        card.style.display = "none";
      }
    });
  });
});

// ----------------------------------------------------
// 3. Profile Name Editing
// ----------------------------------------------------
editNameBtn?.addEventListener("click", () => {
  nameInput.value = playerNameEl.textContent;
  nameEditBox.classList.remove("hidden");
  nameInput.focus();
});

cancelNameBtn?.addEventListener("click", () => {
  nameEditBox.classList.add("hidden");
});

saveNameBtn?.addEventListener("click", () => {
  const newName = nameInput.value.trim();
  if (newName.length < 2) {
    alert("Name must be at least 2 characters.");
    return;
  }
  if (currentUser) {
    localStorage.setItem("arena_name_" + currentUser.id, newName);
  }
  setUserDisplayName(newName);
  nameEditBox.classList.add("hidden");
});

// ----------------------------------------------------
// 4. Realtime Matchmaking with Indian Bot Fallback (bot games)
//    + Real Multiplayer Matchmaking (reaction/tictactoe/quiz/math)
// ----------------------------------------------------
playButtons.forEach(btn => {
  btn.addEventListener("click", async () => {
    activeGame = {
      name: btn.getAttribute("data-game"),
      type: btn.getAttribute("data-type")
    };

    // Re-check against the server balance right before queueing so a
    // stale local number can never let someone queue for a match they
    // can't actually afford.
    await refreshWalletFromServer();
    if (currentBalance < MATCH_ENTRY_FEE) {
      alert("Insufficient balance. You need " + formatINR(MATCH_ENTRY_FEE) + " to enter.");
      return;
    }

    if (REAL_MULTIPLAYER_GAMES.includes(activeGame.type)) {
      currentFlowIsReal = true;
      startRealMatchFlow(activeGame.type);
    } else {
      currentFlowIsReal = false;
      startMatchmaking();
    }
  });
});

function startRealMatchFlow(gameType) {
  if (matchTitle) matchTitle.textContent = "Finding Opponent for " + activeGame.name;
  if (matchStatus) matchStatus.textContent = "Connecting...";
  if (matchOverlay) matchOverlay.classList.remove("hidden");

  startRealMatchmaking(gameType, currentUser.id, (status) => {
    if (status === "insufficient") {
      if (matchOverlay) matchOverlay.classList.add("hidden");
      alert("Insufficient balance. You need " + formatINR(MATCH_ENTRY_FEE) + " to enter.");
      return;
    }
    if (matchStatus) matchStatus.textContent = status;
  });
}

function startMatchmaking() {
  if (matchTitle) matchTitle.textContent = "Finding Opponent for " + activeGame.name;
  if (matchStatus) matchStatus.textContent = "Scanning active queue for live players...";
  if (matchOverlay) matchOverlay.classList.remove("hidden");

  const searchDuration = Math.floor(Math.random() * 3000) + 4000;
  matchmakingTimer = setTimeout(() => {
    const randomIndianBot = INDIAN_BOT_POOL[Math.floor(Math.random() * INDIAN_BOT_POOL.length)];
    pairMatch(randomIndianBot, false);
  }, searchDuration);
}

function pairMatch(opponent, isReal) {
  if (matchmakingTimer) clearTimeout(matchmakingTimer);
