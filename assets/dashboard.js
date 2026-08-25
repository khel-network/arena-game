const MATCH_ENTRY_FEE = 50;
const MATCH_WIN_REWARD = 90;

// Realistic human-like fallback names and avatars
const BOT_POOL = [
  { name: "Alex_94", seed: "alex94" },
  { name: "Marcus_K", seed: "marcusk" },
  { name: "CryptoViper", seed: "viper" },
  { name: "Elena_R", seed: "elena" },
  { name: "ShadowNinja", seed: "shadow" },
  { name: "David_Pro", seed: "davidpro" },
  { name: "Vikram_S", seed: "vikram" },
  { name: "Sarah_Play", seed: "sarah" }
];

// DOM elements
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

// Arena Elements
const arenaOverlay = document.getElementById("game-arena-overlay");
const arenaUserAvatar = document.getElementById("arena-user-avatar");
const arenaUserName = document.getElementById("arena-user-name");
const arenaOppAvatar = document.getElementById("arena-opp-avatar");
const arenaOppName = document.getElementById("arena-opp-name");
const arenaStage = document.getElementById("arena-stage");
const arenaQuitBtn = document.getElementById("arena-quit-btn");

let currentUser = null;
let currentBalance = 0;
let matchmakingTimer = null;
let currentGameType = "reaction";

async function init() {
  try {
    const { data: { session }, error: sessionError } = await client.auth.getSession();

    if (sessionError || !session) {
      window.location.href = "index.html";
      return;
    }

    currentUser = session.user;
    const meta = currentUser.user_metadata || {};
    const displayName = meta.full_name || meta.name || currentUser.email?.split("@")[0] || "Player";

    if (nameEl) nameEl.textContent = displayName;
    if (avatarEl) {
      avatarEl.src = meta.avatar_url || meta.picture || `https://api.dicebear.com/7.x/identicon/svg?seed=${displayName}`;
    }

    // Fetch Token Balance
    const { data: wallet, error: walletError } = await client
      .from("wallet")
      .select("dummy_token")
      .eq("user_id", currentUser.id)
      .single();

    currentBalance = walletError || !wallet ? 0 : wallet.dummy_token;
    updateBalanceDisplay();

    // Show Dashboard
    if (loadingEl) loadingEl.classList.add("hidden");
    if (dashEl) dashEl.classList.remove("hidden");

  } catch (err) {
    console.error("Dashboard error:", err);
  }
}

function updateBalanceDisplay() {
  if (balanceEl) balanceEl.textContent = currentBalance.toLocaleString();
}

async function adjustWalletBalance(amount) {
  currentBalance += amount;
  updateBalanceDisplay();

  try {
    await client
      .from("wallet")
      .update({ dummy_token: currentBalance })
      .eq("user_id", currentUser.id);
  } catch (e) {
    console.warn("Wallet update synced locally:", e);
  }
}

// ----------------------------------------------------
// Matchmaking Logic (5-10s Search -> Realistic Opponent)
// ----------------------------------------------------

playButtons.forEach((btn) => {
  btn.addEventListener("click", () => {
    const gameName = btn.getAttribute("data-game") || "Duel";
    currentGameType = btn.getAttribute("data-type") || "reaction";

    if (currentBalance < MATCH_ENTRY_FEE) {
      alert(`Insufficient balance. You need at least ${MATCH_ENTRY_FEE} tokens.`);
      return;
    }

    startMatchmaking(gameName);
  });
});

function startMatchmaking(gameName) {
  if (matchTitle) matchTitle.textContent = `Finding Opponent for ${gameName}`;
  if (matchStatus) matchStatus.textContent = "Scanning active lobby for players...";
  if (matchOverlay) matchOverlay.classList.remove("hidden");

  // Realistic random wait time (5 to 9 seconds)
  const searchDuration = Math.floor(Math.random() * 4000) + 5000;

  matchmakingTimer = setTimeout(() => {
    // Pick random realistic bot opponent
    const randomOpponent = BOT_POOL[Math.floor(Math.random() * BOT_POOL.length)];
    
    if (matchStatus) matchStatus.textContent = `Opponent Found: ${randomOpponent.name}! Connecting...`;

    setTimeout(() => {
      if (matchOverlay) matchOverlay.classList.add("hidden");
      launchGameArena(randomOpponent);
    }, 1200);

  }, searchDuration);
}

if (cancelMatchBtn) {
  cancelMatchBtn.addEventListener("click", () => {
    if (matchmakingTimer) clearTimeout(matchmakingTimer);
    if (matchOverlay) matchOverlay.classList.add("hidden");
  });
}

// ----------------------------------------------------
// Playable Arena Engine
// ----------------------------------------------------

function launchGameArena(opponent) {
  // Deduct entry fee
  adjustWalletBalance(-MATCH_ENTRY_FEE);

  const meta = currentUser.user_metadata || {};
  const myName = meta.full_name || meta.name || currentUser.email?.split("@")[0] || "You";
  const myAvatar = meta.avatar_url || meta.picture || `https://api.dicebear.com/7.x/identicon/svg?seed=${myName}`;

  arenaUserName.textContent = myName;
  arenaUserAvatar.src = myAvatar;
  arenaOppName.textContent = opponent.name;
  arenaOppAvatar.src = `https://api.dicebear.com/7.x/identicon/svg?seed=${opponent.seed}`;

  arenaOverlay.classList.remove("hidden");
  arenaQuitBtn.classList.add("hidden");

  if (currentGameType === "math") {
    startMathDuel();
  } else {
    startReactionDuel();
  }
}

// 1. REACTION DUEL ENGINE
function startReactionDuel() {
  arenaStage.innerHTML = `
    <div id="reaction-box" class="reaction-box reaction-wait">
      <h2>WAIT FOR GREEN...</h2>
      <p style="margin-top:8px; font-size:0.85rem; opacity:0.8;">Click as fast as possible once it turns green</p>
    </div>
  `;

  const box = document.getElementById("reaction-box");
  let canClick = false;
  let startTime = 0;
  let clicked = false;

  // Random delay before turning green (2.5s - 5s)
  const delay = Math.floor(Math.random() * 2500) + 2500;

  const greenTimeout = setTimeout(() => {
    if (clicked) return;
    canClick = true;
    startTime = Date.now();
    box.className = "reaction-box reaction-go";
    box.querySelector("h2").textContent = "CLICK NOW!";
  }, delay);

  box.addEventListener("click", () => {
    if (clicked) return;
    clicked = true;

    if (!canClick) {
      clearTimeout(greenTimeout);
      finishMatch(false, "Too early! False start.");
    } else {
      const userReactionTime = Date.now() - startTime;
      // Medium bot reacts between 310ms and 450ms
      const botReactionTime = Math.floor(Math.random() * 140) + 310;

      if (userReactionTime < botReactionTime) {
        finishMatch(true, `You clicked in ${userReactionTime}ms! (Opponent: ${botReactionTime}ms)`);
      } else {
        finishMatch(false, `Opponent clicked in ${botReactionTime}ms. (You: ${userReactionTime}ms)`);
      }
    }
  });
}

// 2. MATH DUEL ENGINE
function startMathDuel() {
  const num1 = Math.floor(Math.random() * 20) + 5;
  const num2 = Math.floor(Math.random() * 20) + 5;
  const correctAns = num1 + num2;
  const wrongAns = correctAns + (Math.random() > 0.5 ? 2 : -3);

  const isLeftCorrect = Math.random() > 0.5;
  const optA = isLeftCorrect ? correctAns : wrongAns;
  const optB = isLeftCorrect ? wrongAns : correctAns;

  arenaStage.innerHTML = `
    <div style="text-align:center;">
      <p style="font-size:0.85rem; color:var(--text-muted); margin-bottom:8px;">Fast Arithmetic Duel</p>
      <h2 style="font-size:2.2rem; margin-bottom:20px;">${num1} + ${num2} = ?</h2>
      <div style="display:flex; gap:16px; justify-content:center;">
        <button id="opt-a" class="play-btn" style="min-width:120px; font-size:1.2rem;">${optA}</button>
        <button id="opt-b" class="play-btn" style="min-width:120px; font-size:1.2rem;">${optB}</button>
      </div>
    </div>
  `;

  let answered = false;

  // Medium bot answers correctly in 2.8 - 4.5 seconds
  const botTimer = setTimeout(() => {
    if (!answered) {
      answered = true;
      finishMatch(false, "Opponent answered correctly first!");
    }
  }, Math.floor(Math.random() * 1700) + 2800);

  function handleAnswer(selectedVal) {
    if (answered) return;
    answered = true;
    clearTimeout(botTimer);

    if (selectedVal === correctAns) {
      finishMatch(true, "Correct answer solved fastest!");
    } else {
      finishMatch(false, "Incorrect answer.");
    }
  }

  document.getElementById("opt-a").addEventListener("click", () => handleAnswer(optA));
  document.getElementById("opt-b").addEventListener("click", () => handleAnswer(optB));
}

function finishMatch(won, detailText) {
  if (won) {
    adjustWalletBalance(MATCH_WIN_REWARD);
  }

  arenaStage.innerHTML = `
    <div class="result-box">
      <h2 class="${won ? 'win-text' : 'lose-text'}">${won ? 'VICTORY' : 'DEFEAT'}</h2>
      <p style="color:var(--text-main); font-weight:700; margin-bottom:6px;">${won ? `+${MATCH_WIN_REWARD} Tokens` : '-50 Tokens'}</p>
      <p style="color:var(--text-muted); font-size:0.85rem; margin-bottom:20px;">${detailText}</p>
      <button id="close-arena-btn" class="btn-primary" type="button" style="width:100%;">Return to Dashboard</button>
    </div>
  `;

  document.getElementById("close-arena-btn").addEventListener("click", () => {
    arenaOverlay.classList.add("hidden");
  });
}

// Sign Out
if (logoutBtn) {
  logoutBtn.addEventListener("click", async () => {
    await client.auth.signOut();
    window.location.href = "index.html";
  });
}

init();
