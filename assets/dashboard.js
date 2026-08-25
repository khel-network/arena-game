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

    // Fetch live wallet balance from Supabase
    try {
      const { data: wallet } = await client
        .from("wallet")
        .select("dummy_token")
        .eq("user_id", currentUser.id)
        .single();
      if (wallet && typeof wallet.dummy_token === "number") {
        currentBalance = wallet.dummy_token;
      }
    } catch (e) {
      console.warn("Wallet fetch fallback to local balance:", e);
    }

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

function updateUI() {
  if (balanceEl) balanceEl.textContent = currentBalance.toLocaleString();
  
  const progressPercent = Math.min(100, Math.round((currentBalance / 2500) * 100));
  const progressFill = document.getElementById("progress-fill");
  const progressText = document.getElementById("progress-text");
  if (progressFill) progressFill.style.width = progressPercent + "%";
  if (progressText) {
    progressText.textContent = "$" + (currentBalance / 1000).toFixed(2) + " / $2.50 (" + currentBalance.toLocaleString() + " / 2,500 Tokens)";
  }

  const totalMatches = matchHistory.length;
  const wins = matchHistory.filter(m => m.result === "VICTORY").length;
  const winRate = totalMatches > 0 ? Math.round((wins / totalMatches) * 100) : 0;
  const totalWonTokens = wins * MATCH_WIN_REWARD;

  const statEarnings = document.getElementById("stat-total-earnings");
  const statMatches = document.getElementById("stat-matches-played");
  const statRate = document.getElementById("stat-win-rate");
  const statWon = document.getElementById("stat-tokens-won");

  if (statEarnings) statEarnings.textContent = currentBalance.toLocaleString() + " 🪙";
  if (statMatches) statMatches.textContent = totalMatches;
  if (statRate) statRate.textContent = winRate + "%";
  if (statWon) statWon.textContent = "+" + totalWonTokens.toLocaleString() + " 🪙";

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
      '<td style="font-weight:700; color:' + color + ';">' + sign + tx.amount + ' 🪙</td>' +
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

  const targetTab = Array.from(tabButtons).find(b => b.getAttribute("data-target") === targetId);
  if (targetTab) targetTab.classList.add("active");

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
// 4. Realtime Matchmaking with Indian Bot Fallback
// ----------------------------------------------------
playButtons.forEach(btn => {
  btn.addEventListener("click", () => {
    activeGame = {
      name: btn.getAttribute("data-game"),
      type: btn.getAttribute("data-type")
    };

    if (currentBalance < MATCH_ENTRY_FEE) {
      alert("Insufficient balance. You need " + MATCH_ENTRY_FEE + " tokens to enter.");
      return;
    }

    startMatchmaking();
  });
});

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

  activeOpponent = opponent;
  if (matchStatus) {
    matchStatus.textContent = "Opponent Matched: " + opponent.name + "! Launching arena...";
  }

  setTimeout(() => {
    if (matchOverlay) matchOverlay.classList.add("hidden");
    launchArena(opponent);
  }, 1000);
}

cancelMatchBtn?.addEventListener("click", () => {
  if (matchmakingTimer) clearTimeout(matchmakingTimer);
  if (matchOverlay) matchOverlay.classList.add("hidden");
});

// ----------------------------------------------------
// 5. High-Tech Playable Arena Engine
// ----------------------------------------------------
function launchArena(opponent) {
  currentBalance -= MATCH_ENTRY_FEE;
  recordTransaction("Stake Entry: " + activeGame.name, "debit", MATCH_ENTRY_FEE);

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
  } else {
    runReactionGame();
  }
}

// GAME 1: Reaction Duel
function runReactionGame() {
  arenaStage.innerHTML = 
    '<div id="reaction-box" class="reaction-box reaction-wait">' +
      '<h2 style="font-size:1.4rem;">WAIT FOR GREEN...</h2>' +
      '<p style="font-size:0.8rem; margin-top:6px; opacity:0.85;">Click instantly when the box turns green</p>' +
    '</div>';

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
      endDuel(false, "False Start! You clicked before the signal turned green.", 0, 0);
    } else {
      const userReaction = Date.now() - startTime;
      const botReaction = Math.floor(Math.random() * 120) + 290;

      if (userReaction < botReaction) {
        endDuel(true, "Superior speed! Your reaction: " + userReaction + "ms vs Opponent: " + botReaction + "ms", userReaction, botReaction);
      } else {
        endDuel(false, "Opponent was faster (" + botReaction + "ms). Your speed: " + userReaction + "ms", userReaction, botReaction);
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
    '<div style="width:100%; text-align:center;">' +
      '<p style="color:var(--text-muted); font-size:0.8rem; margin-bottom:6px;">Fast Equation Solve</p>' +
      '<h2 style="font-size:2rem; margin-bottom:20px;">' + n1 + ' + ' + n2 + ' = ?</h2>' +
      '<div style="display:flex; gap:12px; justify-content:center;">' +
        '<button id="opt-a" class="play-btn" style="min-width:110px; font-size:1.1rem;">' + optA + '</button>' +
        '<button id="opt-b" class="play-btn" style="min-width:110px; font-size:1.1rem;">' + optB + '</button>' +
      '</div>' +
    '</div>';

  let answered = false;
  const botAnswerTimer = setTimeout(() => {
    if (!answered) {
      answered = true;
      endDuel(false, "Opponent calculated and answered correctly first!", 0, 0);
    }
  }, Math.floor(Math.random() * 1400) + 2800);

  function pickAnswer(val) {
    if (answered) return;
    answered = true;
    clearTimeout(botAnswerTimer);

    if (val === correct) {
      endDuel(true, "Accurate calculation solved in lightning time!", 0, 0);
    } else {
      endDuel(false, "Incorrect answer calculated.", 0, 0);
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
    '<div style="width:100%; text-align:center;">' +
      '<p style="color:var(--text-muted); font-size:0.8rem; margin-bottom:8px;">Does the word match the font color?</p>' +
      '<h2 style="font-size:2.2rem; color:' + fontColor.css + '; margin-bottom:20px; font-weight:800;">' + targetWord.text + '</h2>' +
      '<div style="display:flex; gap:12px; justify-content:center;">' +
        '<button id="match-yes" class="btn-primary" style="padding:12px;">YES (MATCH)</button>' +
        '<button id="match-no" class="btn-secondary" style="padding:12px;">NO (DIFFERENT)</button>' +
      '</div>' +
    '</div>';

  const isMatching = targetWord.text === fontColor.text;
  let done = false;

  function evaluate(answer) {
    if (done) return;
    done = true;
    if (answer === isMatching) {
      endDuel(true, "Correct cognitive color distinction made!", 0, 0);
    } else {
      endDuel(false, "Incorrect mismatch selected under pressure.", 0, 0);
    }
  }

  document.getElementById("match-yes")?.addEventListener("click", () => evaluate(true));
  document.getElementById("match-no")?.addEventListener("click", () => evaluate(false));
}

// GAME 4: Memory Matrix
function runMemoryMatrixGame() {
  let tilesHtml = "";
  for (let i = 0; i < 9; i++) {
    tilesHtml += '<div class="matrix-tile" data-idx="' + i + '" style="width:54px; height:54px; background:var(--bg-card); border-radius:6px; cursor:pointer;"></div>';
  }
  
  arenaStage.innerHTML = 
    '<div style="text-align:center;">' +
      '<p style="color:var(--text-muted); font-size:0.8rem; margin-bottom:12px;">Memorize the active green tile</p>' +
      '<div style="display:grid; grid-template-columns:repeat(3, 54px); gap:8px; justify-content:center;" id="matrix-grid">' +
        tilesHtml +
      '</div>' +
    '</div>';

  const tiles = document.querySelectorAll(".matrix-tile");
  const activeIndex = Math.floor(Math.random() * 9);

  setTimeout(() => {
    if (tiles[activeIndex]) tiles[activeIndex].style.backgroundColor = "var(--primary-green)";
    setTimeout(() => {
      if (tiles[activeIndex]) tiles[activeIndex].style.backgroundColor = "var(--bg-card)";
      tiles.forEach(t => {
        t.addEventListener("click", () => {
          const clickedIdx = parseInt(t.getAttribute("data-idx"));
          if (clickedIdx === activeIndex) {
            endDuel(true, "Flawless spatial memory recall!", 0, 0);
          } else {
            endDuel(false, "Selected incorrect matrix quadrant.", 0, 0);
          }
        });
      });
    }, 800);
  }, 400);
}

// ----------------------------------------------------
// 6. Post-Match Analytics & Termination
// ----------------------------------------------------
function endDuel(won, analysisText, userStat, oppStat) {
  if (won) {
    currentBalance += MATCH_WIN_REWARD;
    recordTransaction("Duel Victory: " + activeGame.name, "credit", MATCH_WIN_REWARD);
  }

  matchHistory.unshift({
    game: activeGame.name,
    opponent: activeOpponent.name,
    result: won ? "VICTORY" : "DEFEAT",
    reward: won ? ("+" + MATCH_WIN_REWARD + " 🪙") : "-50 🪙",
    date: new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  });
  saveMatches();
  updateUI();

  arenaStage.innerHTML = 
    '<div class="result-card">' +
      '<h2 class="' + (won ? 'win-text' : 'lose-text') + '">' + (won ? 'VICTORY' : 'DEFEAT') + '</h2>' +
      '<p style="font-weight:700; font-size:1.1rem; color:var(--text-main); margin-bottom:4px;">' +
        (won ? ('+' + MATCH_WIN_REWARD + ' Tokens Awarded') : '-50 Tokens Stake Lost') +
      '</p>' +
      '<div class="result-analytics">' +
        '<p style="margin-bottom:4px;"><strong>Performance Analytics:</strong></p>' +
        '<p>' + analysisText + '</p>' +
      '</div>' +
      '<div class="result-btn-row">' +
        '<button id="rematch-btn" class="btn-primary" type="button">Rematch</button>' +
        '<button id="return-dash-btn" class="btn-secondary" type="button">Dashboard</button>' +
      '</div>' +
    '</div>';

  document.getElementById("rematch-btn")?.addEventListener("click", () => {
    arenaOverlay.classList.add("hidden");
    startMatchmaking();
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
