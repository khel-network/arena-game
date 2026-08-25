const MATCH_ENTRY_FEE = 50;
const MATCH_WIN_REWARD = 90;

// Indian Names Pool for Simulated Real-Player Fallback
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
let currentBalance = 0;
let matchHistory = [];
let transactions = [];
let activeOpponent = null;
let activeGame = null;
let matchmakingTimer = null;
let realUserChannel = null;

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
    const { data: { session }, error: sessionError } = await client.auth.getSession();

    if (sessionError || !session) {
      window.location.href = "index.html";
      return;
    }

    currentUser = session.user;
    loadLocalUserData();

    // Fetch live wallet balance from Supabase
    const { data: wallet } = await client
      .from("wallet")
      .select("dummy_token")
      .eq("user_id", currentUser.id)
      .single();

    currentBalance = wallet ? wallet.dummy_token : 1000;
    updateUI();

    // Show Dashboard
    if (loadingEl) loadingEl.classList.add("hidden");
    if (dashEl) dashEl.classList.remove("hidden");

  } catch (err) {
    console.error("Initialization error:", err);
  }
}

function loadLocalUserData() {
  const savedName = localStorage.getItem(`arena_name_${currentUser.id}`);
  const meta = currentUser.user_metadata || {};
  const initialName = savedName || meta.full_name || meta.name || currentUser.email?.split("@")[0] || "Player";

  // Initial welcome transaction if empty
  const storedTx = localStorage.getItem(`arena_tx_${currentUser.id}`);
  if (storedTx) {
    transactions = JSON.parse(storedTx);
  } else {
    transactions = [
      { desc: "Welcome Bonus Credited", type: "credit", amount: 1000, date: new Date().toLocaleString() }
    ];
    saveTransactions();
  }

  const storedMatches = localStorage.getItem(`arena_matches_${currentUser.id}`);
  if (storedMatches) matchHistory = JSON.parse(storedMatches);

  setUserDisplayName(initialName);
}

function setUserDisplayName(name) {
  if (playerNameEl) playerNameEl.textContent = name;
  if (profileDisplayName) profileDisplayName.textContent = name;
  const avatarUrl = `https://api.dicebear.com/7.x/identicon/svg?seed=${name}`;
  if (avatarEl) avatarEl.src = avatarUrl;
  if (profileViewAvatar) profileViewAvatar.src = avatarUrl;
}

function updateUI() {
  if (balanceEl) balanceEl.textContent = currentBalance.toLocaleString();
  
  // Update Cashout Progress bar ($1 per 1,000 tokens, $2.50 goal = 2,500 tokens)
  const progressPercent = Math.min(100, Math.round((currentBalance / 2500) * 100));
  const progressFill = document.getElementById("progress-fill");
  const progressText = document.getElementById("progress-text");
  if (progressFill) progressFill.style.width = `${progressPercent}%`;
  if (progressText) {
    progressText.textContent = `$${(currentBalance / 1000).toFixed(2)} / $2.50 (${currentBalance.toLocaleString()} / 2,500 Tokens)`;
  }

  // Update Stats in Profile
  const totalMatches = matchHistory.length;
  const wins = matchHistory.filter(m => m.result === "VICTORY").length;
  const winRate = totalMatches > 0 ? Math.round((wins / totalMatches) * 100) : 0;
  const totalWonTokens = wins * MATCH_WIN_REWARD;

  const statEarnings = document.getElementById("stat-total-earnings");
  const statMatches = document.getElementById("stat-matches-played");
  const statRate = document.getElementById("stat-win-rate");
  const statWon = document.getElementById("stat-tokens-won");

  if (statEarnings) statEarnings.textContent = `${(currentBalance).toLocaleString()} 🪙`;
  if (statMatches) statMatches.textContent = totalMatches;
  if (statRate) statRate.textContent = `${winRate}%`;
  if (statWon) stat
