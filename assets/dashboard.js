const MATCH_ENTRY_FEE = 50;
const MATCH_WIN_REWARD = 90;
const BOT_WAIT_SECONDS = 5; // how long to wait for a real opponent before matching with a bot

// Indian Names Pool for Bot Fallback (boys & girls)
const INDIAN_BOT_POOL = [
  { name: "Aarav Sharma", seed: "aarav" },
  { name: "Priya Patel", seed: "priya" },
  { name: "Rohan Verma", seed: "rohan" },
  { name: "Ananya Singh", seed: "ananya" },
  { name: "Vikram Malhotra", seed: "vikram" },
  { name: "Sneha Reddy", seed: "sneha" },
  { name: "Aditya Kumar", seed: "aditya" },
  { name: "Neha Gupta", seed: "neha" },
  { name: "Karan Mehta", seed: "karan" },
  { name: "Divya Roy", seed: "divya" },
  { name: "Arjun Chopra", seed: "arjun" },
  { name: "Riya Sen", seed: "riya" },
  { name: "Ishaan Kapoor", seed: "ishaan" },
  { name: "Meera Nair", seed: "meera" },
  { name: "Rahul Iyer", seed: "rahul" },
  { name: "Kavya Joshi", seed: "kavya" }
];

function formatRupees(amount) {
  const n = Number(amount) || 0;
  const sign = n < 0 ? "-" : "";
  return sign + "\u20b9" + Math.abs(n).toLocaleString("en-IN");
}

// App State
let currentUser = null;
let currentBalance = 0;
let matchHistory = [];
let transactions = [];
let activeOpponent = null;
let activeGame = null;
let matchmakingTimer = null;
let queueChannel = null;
let inQueue = false;

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

    loadUserName();
    await loadWallet();
    await loadTransactions();
    await loadMatchHistory();
    updateUI();
  } catch (err) {
    console.error("Initialization error:", err);
  } finally {
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

function loadUserName() {
  const savedName = localStorage.getItem("arena_name_" + currentUser.id);
  const meta = currentUser.user_metadata || {};
  const initialName =
    savedName ||
    meta.full_name ||
    meta.name ||
    (currentUser.email ? currentUser.email.split("@")[0] : "Player");
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
// 2. Wallet — always backed by Supabase, never local-only
// ----------------------------------------------------
async function loadWallet() {
  try {
    const { data: wallet, error } = await client
      .from("wallet")
      .select("dummy_token")
      .eq("user_id", currentUser.id)
      .single();
    if (error) throw error;
    currentBalance = (wallet && typeof wallet.dummy_token === "number") ? wallet.dummy_token : 0;
  } catch (e) {
    console.warn("Wallet fetch failed:", e);
    currentBalance = 0;
  }
}

// Applies a delta (+credit / -debit) to the Supabase wallet and keeps currentBalance in sync.
// This is the single source of truth fix for the "resets on refresh" bug.
async function persistWalletDelta(delta) {
  const { data: wallet, error } = await client
    .from("wallet")
    .select("dummy_token")
    .eq("user_id", currentUser.id)
    .single();
  if (error || !wallet) throw error || new Error("Wallet not found");

  const newBalance = Math.max(0, (wallet.dummy_token || 0) + delta);
  const { error: updErr } = await client
    .from("wallet")
    .update({ dummy_token: newBalance, updated_at: new Date().toISOString() })
    .eq("user_id", currentUser.id);
  if (updErr) throw updErr;

  currentBalance = newBalance;
  flashBalance();
  return newBalance;
}

function flashBalance() {
  if (!balanceEl) return;
  balanceEl.classList.remove("balance-flash");
  void balanceEl.offsetWidth; // restart animation
  balanceEl.classList.add("balance-flash");
}

// ----------------------------------------------------
// 3. Transactions & Match History — persisted, not local-only
// ----------------------------------------------------
async function loadTransactions() {
  try {
    const { data, error } = await client
      .from("transactions")
      .select("description, type, amount, created_at")
      .eq("user_id", currentUser.id)
      .order("created_at", { ascending: false })
      .limit(50);
    if (error) throw error;
    transactions = (data || []).map((t) => ({
      desc: t.description,
      type: t.type,
      amount: t.amount,
      date: new Date(t.created_at).toLocaleString()
    }));
  } catch (e) {
    console.warn("Could not load transactions (run schema3.sql to enable the live ledger):", e);
    transactions = [];
  }
}

async function recordTransaction(desc, type, amount) {
  transactions.unshift({ desc, type, amount, date: new Date().toLocaleString() });
  updateUI();
  try {
    const { error } = await client.from("transactions").insert({
      user_id: currentUser.id,
      description: desc,
      type,
      amount
    });
    if (error) throw error;
  } catch (e) {
    console.warn("Transaction not persisted (run schema3.sql):", e);
  }
}

async function loadMatchHistory() {
  try {
    const { data, error } = await client
      .from("match_history")
      .select("game, opponent, result, reward, created_at")
      .eq("user_id", currentUser.id)
      .order("created_at", { ascending: false })
      .limit(50);
    if (error) throw error;
    matchHistory = (data || []).map((m) => ({
      game: m.game,
      opponent: m.opponent,
      result: m.result,
      reward: m.reward,
      date: new Date(m.created_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
    }));
  } catch (e) {
    console.warn("Could not load match history (run schema3.sql to enable this):", e);
    matchHistory = [];
  }
}

async function recordMatch(game, opponent, result, reward) {
  matchHistory.unshift({
    game,
    opponent,
    result,
    reward,
    date: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
  });
  updateUI();
  try {
    const { error } = await client.from("match_history").insert({
      user_id: currentUser.id,
      game,
      opponent,
      result,
      reward
    });
    if (error) throw error;
  } catch (e) {
    console.warn("Match result not persisted (run schema3.sql):", e);
  }
}

// ----------------------------------------------------
// 4. UI Rendering
// ----------------------------------------------------
function updateUI() {
  if (balanceEl) balanceEl.textContent = currentBalance.toLocaleString("en-IN");

  const progressPercent = Math.min(100, Math.round((currentBalance / 2500) * 100));
  const progressFill = document.getElementById("progress-fill");
  const progressText = document.getElementById("progress-text");
  if (progressFill) progressFill.style.width = progressPercent + "%";
  if (progressText) {
    progressText.textContent =
      formatRupees(currentBalance) + " / " + formatRupees(2500) + " Cashout Threshold";
  }

  const totalMatches = matchHistory.length;
  const wins = matchHistory.filter((m) => m.result === "VICTORY").length;
  const winRate = totalMatches > 0 ? Math.round((wins / totalMatches) * 100) : 0;
  const totalWonTokens = wins * MATCH_WIN_REWARD;

  const statEarnings = document.getElementById("stat-total-earnings");
  const statMatches = document.getElementById("stat-matches-played");
  const statRate = document.getElementById("stat-win-rate");
  const statWon = document.getElementById("stat-tokens-won");
  if (statEarnings) statEarnings.textContent = formatRupees(currentBalance);
  if (statMatches) statMatches.textContent = totalMatches;
  if (statRate) statRate.textContent = winRate + "%";
  if (statWon) statWon.textContent = "+" + formatRupees(totalWonTokens);

  renderLedger();
  renderMatchHistory();
}

function renderLedger() {
  const tbody = document.getElementById("ledger-body");
  if (!tbody) return;
  if (transactions.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4">No transactions recorded</td></tr>';
    return;
  }
  tbody.innerHTML = transactions
    .map((tx) => {
      const isCredit = tx.type === "credit";
      const sign = isCredit ? "+" : "-";
      const color = isCredit ? "var(--primary-green)" : "var(--accent-red)";
      const badgeClass = isCredit ? "badge-credit" : "badge-debit";
      return (
        "<tr>" +
        "<td>" + tx.desc + "</td>" +
        '<td><span class="' + badgeClass + '">' + tx.type.toUpperCase() + "</span></td>" +
        '<td style="color:' + color + '">' + sign + formatRupees(tx.amount) + "</td>" +
        "<td>" + tx.date + "</td>" +
        "</tr>"
      );
    })
    .join("");
}

function renderMatchHistory() {
  const tbody = document.getElementById("matches-body");
  if (!tbody) return;
  if (matchHistory.length === 0) {
    tbody.innerHTML = '<tr><td colspan="5">No matches played yet. Choose a game above!</td></tr>';
    return;
  }
  tbody.innerHTML = matchHistory
    .map((m) => {
      const isWin = m.result === "VICTORY";
      const color = isWin ? "var(--primary-green)" : "var(--accent-red)";
      const badgeClass = isWin ? "badge-credit" : "badge-debit";
      const rewardText = (m.reward >= 0 ? "+" : "") + formatRupees(m.reward);
      return (
        "<tr>" +
        "<td>" + m.game + "</td>" +
        "<td>" + m.opponent + "</td>" +
        '<td><span class="' + badgeClass + '">' + m.result + "</span></td>" +
        '<td style="color:' + color + '">' + rewardText + "</td>" +
        "<td>" + m.date + "</td>" +
        "</tr>"
      );
    })
    .join("");
}

// ----------------------------------------------------
// 5. Navigation & Category Filters
// ----------------------------------------------------
function switchView(targetId) {
  tabButtons.forEach((b) => b.classList.remove("active"));
  appViews.forEach((v) => v.classList.remove("active"));
  const targetTab = Array.from(tabButtons).find((b) => b.getAttribute("data-target") === targetId);
  if (targetTab) targetTab.classList.add("active");
  const targetView = document.getElementById(targetId);
  if (targetView) targetView.classList.add("active");
}
tabButtons.forEach((btn) => {
  btn.addEventListener("click", () => switchView(btn.getAttribute("data-target")));
});
document.getElementById("profile-nav-btn")?.addEventListener("click", () => switchView("view-profile"));
document.getElementById("nav-brand-logo")?.addEventListener("click", () => switchView("view-earn"));

filterChips.forEach((chip) => {
  chip.addEventListener("click", () => {
    filterChips.forEach((c) => c.classList.remove("active"));
    chip.classList.add("active");
    const category = chip.getAttribute("data-category");
    gameCards.forEach((card) => {
      if (category === "all" || card.getAttribute("data-category") === category) {
        card.style.display = "flex";
      } else {
        card.style.display = "none";
      }
    });
  });
});

// ----------------------------------------------------
// 6. Profile Name Editing
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
// 7. Real Matchmaking (live users first, bot after 5s)
// ----------------------------------------------------
playButtons.forEach((btn) => {
  btn.addEventListener("click", () => {
    activeGame = { name: btn.getAttribute("data-game"), type: btn.getAttribute("data-type") };
    if (currentBalance < MATCH_ENTRY_FEE) {
      alert("Insufficient balance. You need " + formatRupees(MATCH_ENTRY_FEE) + " to enter.");
      return;
    }
    beginMatchmaking();
  });
});

async function beginMatchmaking() {
  inQueue = true;
  if (matchTitle) matchTitle.textContent = "Finding Opponent \u2014 " + activeGame.name;
  if (matchStatus) matchStatus.textContent = "Deducting entry stake...";
  if (matchOverlay) matchOverlay.classList.remove("hidden");

  try {
    await persistWalletDelta(-MATCH_ENTRY_FEE);
    await recordTransaction("Stake Entry: " + activeGame.name, "debit", MATCH_ENTRY_FEE);
  } catch (e) {
    console.error(e);
    if (matchOverlay) matchOverlay.classList.add("hidden");
    alert("Could not process your entry stake. Please try again.");
    inQueue = false;
    return;
  }

  if (matchStatus) matchStatus.textContent = "Scanning live queue for players...";

  // 1. Is someone already waiting for this game?
  const { data: waiting } = await client
    .from("matchmaking_queue")
    .select("user_id, created_at")
    .eq("game_type", activeGame.type)
    .neq("user_id", currentUser.id)
    .order("created_at", { ascending: true })
    .limit(1);

  if (waiting && waiting.length > 0) {
    const opponentId = waiting[0].user_id;
    await client.from("matchmaking_queue").delete().eq("user_id", opponentId);
    const { data: match, error } = await client
      .from("matches")
      .insert({
        game_type: activeGame.type,
        player1_id: opponentId,
        player2_id: currentUser.id,
        entry_fee: MATCH_ENTRY_FEE
      })
      .select()
      .single();
    if (!error && match) {
      if (matchStatus) matchStatus.textContent = "Live opponent found! Launching arena...";
      cleanupQueue();
      setTimeout(() => {
        window.location.href = "match.html?id=" + match.id + "&game=" + activeGame.type;
      }, 600);
      return;
    }
  }

  // 2. No one waiting — join the queue myself and watch for a live opponent
  await client.from("matchmaking_queue").upsert({ user_id: currentUser.id, game_type: activeGame.type });

  queueChannel = client
    .channel("queue-watch-" + currentUser.id)
    .on(
      "postgres_changes",
      { event: "INSERT", schema: "public", table: "matches", filter: "player2_id=eq." + currentUser.id },
      (payload) => {
        if (!inQueue) return;
        cleanupQueue();
        if (matchStatus) matchStatus.textContent = "Live opponent found! Launching arena...";
        setTimeout(() => {
          window.location.href = "match.html?id=" + payload.new.id + "&game=" + activeGame.type;
        }, 500);
      }
    )
    .subscribe();

  let secondsLeft = BOT_WAIT_SECONDS;
  if (matchStatus) matchStatus.textContent = "Waiting for a live player... (" + secondsLeft + "s)";

  matchmakingTimer = setInterval(async () => {
    if (!inQueue) return;
    secondsLeft -= 1;

    if (secondsLeft > 0) {
      if (matchStatus) matchStatus.textContent = "Waiting for a live player... (" + secondsLeft + "s)";
      // Poll as a backup in case realtime missed the insert
      const { data: mine } = await client
        .from("matches")
        .select("id")
        .or("player1_id.eq." + currentUser.id + ",player2_id.eq." + currentUser.id)
        .eq("status", "active")
        .order("created_at", { ascending: false })
        .limit(1);
      if (mine && mine.length > 0) {
        cleanupQueue();
        if (matchStatus) matchStatus.textContent = "Live opponent found! Launching arena...";
        setTimeout(() => {
          window.location.href = "match.html?id=" + mine[0].id + "&game=" + activeGame.type;
        }, 400);
      }
      return;
    }

    // Timed out — fall back to a bot
    cleanupQueue();
    await client.from("matchmaking_queue").delete().eq("user_id", currentUser.id);
    const bot = INDIAN_BOT_POOL[Math.floor(Math.random() * INDIAN_BOT_POOL.length)];
    if (matchStatus) matchStatus.textContent = "No live players nearby \u2014 matched with " + bot.name;
    setTimeout(() => {
      if (matchOverlay) matchOverlay.classList.add("hidden");
      launchArena(bot);
    }, 900);
  }, 1000);
}

function cleanupQueue() {
  inQueue = false;
  if (matchmakingTimer) {
    clearInterval(matchmakingTimer);
    matchmakingTimer = null;
  }
  if (queueChannel) {
    client.removeChannel(queueChannel);
    queueChannel = null;
  }
}

cancelMatchBtn?.addEventListener("click", async () => {
  const wasInQueue = inQueue;
  cleanupQueue();
  if (matchOverlay) matchOverlay.classList.add("hidden");
  if (currentUser && wasInQueue) {
    await client.from("matchmaking_queue").delete().eq("user_id", currentUser.id);
    try {
      await persistWalletDelta(MATCH_ENTRY_FEE);
      await recordTransaction("Stake Refunded: " + (activeGame ? activeGame.name : "Match"), "credit", MATCH_ENTRY_FEE);
    } catch (e) {
      console.warn(e);
    }
  }
});

// ----------------------------------------------------
// 8. Arena Engine
// ----------------------------------------------------
function launchArena(opponent) {
  activeOpponent = opponent;
  const myName = playerNameEl.textContent;
  arenaUserName.textContent = myName;
  arenaUserAvatar.src = "https://api.dicebear.com/7.x/identicon/svg?seed=" + encodeURIComponent(myName);
  arenaOppName.textContent = opponent.name;
  arenaOppAvatar.src = "https://api.dicebear.com/7.x/identicon/svg?seed=" + opponent.seed;
  arenaOverlay.classList.remove("hidden");

  if (activeGame.type === "math") {
    runCyberMathGame();
  } else if (activeGame.type === "memory") {
    runMemoryMatrixGame();
  } else if (activeGame.type === "color") {
    runColorClashGame();
  } else if (activeGame.type === "tictactoe") {
    runTicTacToeGame();
  } else {
    runReactionGame();
  }
}

// GAME 1: Reaction Duel
function runReactionGame() {
  arenaStage.innerHTML =
    '<div class="reaction-box reaction-wait" id="reaction-box">' +
    "<h2>WAIT FOR GREEN...</h2>" +
    '<p style="margin-top:8px;font-size:0.8rem;opacity:0.85">Click instantly when the box turns green</p>' +
    "</div>";
  const box = document.getElementById("reaction-box");
  let canClick = false;
  let startTime = 0;
  let finished = false;
  const greenDelay = Math.floor(Math.random() * 2200) + 2400;
  const timeoutId = setTimeout(() => {
    if (finished) return;
    canClick = true;
    startTime = Date.now();
    box.className = "reaction-box reaction-go";
    box.querySelector("h2").textContent = "CLICK NOW!";
  }, greenDelay);

  box.addEventListener("click", () => {
    if (finished) return;
    finished = true;
    if (!canClick) {
      clearTimeout(timeoutId);
      endDuel(false, "False Start! You clicked before the signal turned green.");
    } else {
      const userReaction = Date.now() - startTime;
      const botReaction = Math.floor(Math.random() * 120) + 290;
      if (userReaction < botReaction) {
        endDuel(true, "Superior speed! Your reaction: " + userReaction + "ms vs Opponent: " + botReaction + "ms");
      } else {
        endDuel(false, "Opponent was faster (" + botReaction + "ms). Your speed: " + userReaction + "ms");
      }
    }
  });
}

// GAME 2: Cyber Math Duel
function runCyberMathGame() {
  const n1 = Math.floor(Math.random() * 30) + 12;
  const n2 = Math.floor(Math.random() * 30) + 12;
  const correct = n1 + n2;
  const wrong = correct + (Math.random() > 0.5 ? 4 : -5);
  const leftIsCorrect = Math.random() > 0.5;
  const optA = leftIsCorrect ? correct : wrong;
  const optB = leftIsCorrect ? wrong : correct;

  arenaStage.innerHTML =
    '<div style="width:100%;text-align:center">' +
    '<p class="subtitle">Fast Equation Solve</p>' +
    '<div class="math-problem">' + n1 + " + " + n2 + " = ?</div>" +
    '<div class="quiz-options">' +
    '<button class="quiz-option" id="opt-a">' + optA + "</button>" +
    '<button class="quiz-option" id="opt-b">' + optB + "</button>" +
    "</div>" +
    "</div>";

  let answered = false;
  const botAnswerTimer = setTimeout(() => {
    if (!answered) {
      answered = true;
      endDuel(false, "Opponent calculated and answered correctly first!");
    }
  }, Math.floor(Math.random() * 1400) + 2800);

  function pickAnswer(val) {
    if (answered) return;
    answered = true;
    clearTimeout(botAnswerTimer);
    if (val === correct) {
      endDuel(true, "Accurate calculation solved in lightning time!");
    } else {
      endDuel(false, "Incorrect answer calculated.");
    }
  }
  document.getElementById("opt-a")?.addEventListener("click", () => pickAnswer(optA));
  document.getElementById("opt-b")?.addEventListener("click", () => pickAnswer(optB));
}

// GAME 3: Color Clash
function runColorClashGame() {
  const colors = [
    { text: "RED", css: "#ef4444" },
    { text: "BLUE", css: "#38bdf8" },
    { text: "GREEN", css: "#00e701" }
  ];
  const targetWord = colors[Math.floor(Math.random() * colors.length)];
  const fontColor = colors[Math.floor(Math.random() * colors.length)];

  arenaStage.innerHTML =
    '<div style="width:100%;text-align:center">' +
    '<p class="subtitle">Does the word match the font color?</p>' +
    '<div class="quiz-question" style="color:' + fontColor.css + '">' + targetWord.text + "</div>" +
    '<div class="quiz-options">' +
    '<button class="quiz-option" id="match-yes">YES (MATCH)</button>' +
    '<button class="quiz-option" id="match-no">NO (DIFFERENT)</button>' +
    "</div>" +
    "</div>";

  const isMatching = targetWord.text === fontColor.text;
  let done = false;
  function evaluate(answer) {
    if (done) return;
    done = true;
    if (answer === isMatching) {
      endDuel(true, "Correct cognitive color distinction made!");
    } else {
      endDuel(false, "Incorrect mismatch selected under pressure.");
    }
  }
  document.getElementById("match-yes")?.addEventListener("click", () => evaluate(true));
  document.getElementById("match-no")?.addEventListener("click", () => evaluate(false));
}

// GAME 4: Memory Matrix
function runMemoryMatrixGame() {
  let tilesHtml = "";
  for (let i = 0; i < 9; i++) {
    tilesHtml += '<div class="matrix-tile" data-idx="' + i + '" style="width:60px;height:60px;background-color:var(--bg-card);border-radius:8px;cursor:pointer;border:1px solid var(--border-color)"></div>';
  }
  arenaStage.innerHTML =
    '<div style="width:100%;text-align:center">' +
    '<p class="subtitle">Memorize the active green tile</p>' +
    '<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:10px;max-width:220px;margin:16px auto">' +
    tilesHtml +
    "</div>" +
    "</div>";

  const tiles = document.querySelectorAll(".matrix-tile");
  const activeIndex = Math.floor(Math.random() * 9);
  setTimeout(() => {
    if (tiles[activeIndex]) tiles[activeIndex].style.backgroundColor = "var(--primary-green)";
    setTimeout(() => {
      if (tiles[activeIndex]) tiles[activeIndex].style.backgroundColor = "var(--bg-card)";
      tiles.forEach((t) => {
        t.addEventListener("click", () => {
          const clickedIdx = parseInt(t.getAttribute("data-idx"));
          if (clickedIdx === activeIndex) {
            endDuel(true, "Flawless spatial memory recall!");
          } else {
            endDuel(false, "Selected incorrect matrix quadrant.");
          }
        });
      });
    }, 800);
  }, 400);
}

// GAME 5: Tic-Tac-Toe Blitz (classic 3x3, 5-second per-turn clock)
function runTicTacToeGame() {
  const board = Array(9).fill(null);
  const WIN_LINES = [
    [0, 1, 2], [3, 4, 5], [6, 7, 8],
    [0, 3, 6], [1, 4, 7], [2, 5, 8],
    [0, 4, 8], [2, 4, 6],
  ];
  let playerTurn = true; // player is always X and moves first
  let over = false;
  let timerInterval = null;
  let timeLeft = 5;

  renderBoard();
  startTurnTimer();

  function renderBoard() {
    let cellsHtml = "";
    board.forEach((val, i) => {
      cellsHtml +=
        '<div class="ttt-cell' + (val ? " filled" : "") + '" data-idx="' + i + '">' +
        (val || "") +
        "</div>";
    });
    arenaStage.innerHTML =
      '<div style="width:100%;text-align:center">' +
      '<p class="subtitle">You are X &middot; Opponent is O</p>' +
      '<p class="loading-text" id="ttt-turn-label">' +
      (over ? "" : playerTurn ? "Your move" : "Opponent's move") +
      "</p>" +
      '<p style="font-weight:700;color:var(--accent-red);margin-bottom:6px;min-height:20px" id="ttt-timer">' +
      (playerTurn && !over ? "\u23F1 " + timeLeft + "s" : "") +
      "</p>" +
      '<div class="ttt-board" id="ttt-board">' + cellsHtml + "</div>" +
      "</div>";

    if (playerTurn && !over) {
      document.querySelectorAll("#ttt-board .ttt-cell").forEach((cell) => {
        cell.addEventListener("click", () => handlePlayerMove(parseInt(cell.getAttribute("data-idx"), 10)));
      });
    }
  }

  function startTurnTimer() {
    clearInterval(timerInterval);
    if (over || !playerTurn) return;
    timeLeft = 5;
    timerInterval = setInterval(() => {
      timeLeft -= 1;
      const timerEl = document.getElementById("ttt-timer");
      if (timerEl) timerEl.textContent = "\u23F1 " + timeLeft + "s";
      if (timeLeft <= 0) {
        clearInterval(timerInterval);
        if (!over) {
          over = true;
          endDuel(false, "Time expired on your turn \u2014 match forfeited under Blitz rules.");
        }
      }
    }, 1000);
  }

  function handlePlayerMove(idx) {
    if (over || !playerTurn || board[idx]) return;
    clearInterval(timerInterval);
    board[idx] = "X";
    playerTurn = false;
    renderBoard();
    if (checkEnd()) return;
    setTimeout(botMove, 550);
  }

  function botMove() {
    if (over) return;
    const idx = pickBotMove();
    board[idx] = "O";
    playerTurn = true;
    renderBoard();
    if (checkEnd()) return;
    startTurnTimer();
  }

  function pickBotMove() {
    const empty = board.map((v, i) => (v ? null : i)).filter((v) => v !== null);
    for (const i of empty) {
      board[i] = "O";
      if (hasWinner("O")) { board[i] = null; return i; }
      board[i] = null;
    }
    for (const i of empty) {
      board[i] = "X";
      if (hasWinner("X")) { board[i] = null; return i; }
      board[i] = null;
    }
    if (!board[4]) return 4;
    const corners = [0, 2, 6, 8].filter((i) => !board[i]);
    if (corners.length) return corners[Math.floor(Math.random() * corners.length)];
    return empty[Math.floor(Math.random() * empty.length)];
  }

  function hasWinner(symbol) {
    return WIN_LINES.some((line) => line.every((i) => board[i] === symbol));
  }

  function checkEnd() {
    if (hasWinner("X")) {
      over = true;
      setTimeout(() => endDuel(true, "Completed a winning line before your opponent!"), 400);
      return true;
    }
    if (hasWinner("O")) {
      over = true;
      setTimeout(() => endDuel(false, "Opponent completed a winning line first."), 400);
      return true;
    }
    if (board.every((c) => c)) {
      over = true;
      setTimeout(endDrawnMatch, 400);
      return true;
    }
    return false;
  }

  async function endDrawnMatch() {
    try {
      await persistWalletDelta(MATCH_ENTRY_FEE);
      await recordTransaction("Stake Refunded: " + activeGame.name, "credit", MATCH_ENTRY_FEE);
      await recordMatch(activeGame.name, activeOpponent.name, "DRAW", 0);
    } catch (e) {
      console.warn(e);
    }
    updateUI();

    arenaStage.innerHTML =
      '<div class="result-card">' +
      '<h2 style="color:var(--text-main)">DRAW</h2>' +
      '<p style="font-weight:700;color:var(--text-muted)">Stake Refunded</p>' +
      '<div class="result-analytics">' +
      '<div style="font-weight:700;color:var(--text-main);margin-bottom:4px">Performance Analytics:</div>' +
      "<div>Full board stalemate \u2014 neither player completed a line. Entry fee refunded.</div>" +
      "</div>" +
      '<div class="result-btn-row">' +
      '<button class="btn-secondary" id="rematch-btn">Rematch</button>' +
      '<button class="btn-primary" id="return-dash-btn">Dashboard</button>' +
      "</div>" +
      "</div>";

    document.getElementById("rematch-btn")?.addEventListener("click", () => {
      arenaOverlay.classList.add("hidden");
      if (currentBalance < MATCH_ENTRY_FEE) {
        alert("Insufficient balance. You need " + formatRupees(MATCH_ENTRY_FEE) + " to enter.");
        return;
      }
      beginMatchmaking();
    });
    document.getElementById("return-dash-btn")?.addEventListener("click", () => {
      arenaOverlay.classList.add("hidden");
    });
  }
}

// ----------------------------------------------------
// 9. Post-Match Resolution — now fully persisted
// ----------------------------------------------------
async function endDuel(won, analysisText) {
  let reward = -MATCH_ENTRY_FEE;

  if (won) {
    try {
      await persistWalletDelta(MATCH_WIN_REWARD);
      await recordTransaction("Duel Victory: " + activeGame.name, "credit", MATCH_WIN_REWARD);
      reward = MATCH_WIN_REWARD;
    } catch (e) {
      console.error("Failed to credit winnings:", e);
    }
  }

  await recordMatch(activeGame.name, activeOpponent.name, won ? "VICTORY" : "DEFEAT", reward);
  updateUI();

  const rewardLine = won
    ? "+" + formatRupees(MATCH_WIN_REWARD) + " Awarded"
    : formatRupees(-MATCH_ENTRY_FEE) + " Stake Lost";

  arenaStage.innerHTML =
    '<div class="result-card">' +
    '<h2 class="' + (won ? "win-text" : "lose-text") + '">' + (won ? "VICTORY" : "DEFEAT") + "</h2>" +
    '<p style="font-weight:700;color:var(--text-muted)">' + rewardLine + "</p>" +
    '<div class="result-analytics">' +
    '<div style="font-weight:700;color:var(--text-main);margin-bottom:4px">Performance Analytics:</div>' +
    "<div>" + analysisText + "</div>" +
    "</div>" +
    '<div class="result-btn-row">' +
    '<button class="btn-secondary" id="rematch-btn">Rematch</button>' +
    '<button class="btn-primary" id="return-dash-btn">Dashboard</button>' +
    "</div>" +
    "</div>";

  document.getElementById("rematch-btn")?.addEventListener("click", () => {
    arenaOverlay.classList.add("hidden");
    if (currentBalance < MATCH_ENTRY_FEE) {
      alert("Insufficient balance. You need " + formatRupees(MATCH_ENTRY_FEE) + " to enter.");
      return;
    }
    beginMatchmaking();
  });
  document.getElementById("return-dash-btn")?.addEventListener("click", () => {
    arenaOverlay.classList.add("hidden");
  });
}

logoutBtn?.addEventListener("click", async () => {
  await client.auth.signOut();
  window.location.href = "index.html";
});

init();
