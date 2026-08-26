const MatchRoom = (() => {
  let match = null;
  let myId = null;
  let opponentId = null;
  let iAmPlayer1 = false;
  let channel = null;
  let finished = false;
  const handlers = {};
  async function init(matchId, userId) {
    myId = userId;
    const { data, error } = await client
      .from("matches")
      .select("*")
      .eq("id", matchId)
      .single();
    if (error || !data) {
      throw new Error("Match not found");
    }
    match = data;
    iAmPlayer1 = match.player1_id === myId;
    opponentId = iAmPlayer1 ? match.player2_id : match.player1_id;
    channel = client.channel(`match-${matchId}`, {
      config: { broadcast: { self: false } },
    });
    channel.on("broadcast", { event: "move" }, (payload) => {
      const { type, data } = payload.payload;
      if (handlers[type]) handlers[type](data);
    });
    await new Promise((resolve) => {
      channel.subscribe((status) => {
        if (status === "SUBSCRIBED") resolve();
      });
    });
    return { match, opponentId, iAmPlayer1 };
  }
  function send(type, data) {
    channel.send({ type: "broadcast", event: "move", payload: { type, data } });
  }
  function onMessage(type, handler) {
    handlers[type] = handler;
  }
  async function finish(result) {
    if (finished) return;
    finished = true;
    await client
      .from("matches")
      .update({
        status: "finished",
        winner_id: result === "win" ? myId : result === "lose" ? opponentId : null,
        finished_at: new Date().toISOString(),
      })
      .eq("id", match.id)
      .eq("status", "active");
    if (result === "win") {
      const payout = Math.round(match.entry_fee * 1.8);
      const { data: wallet } = await client
        .from("wallet")
        .select("dummy_token")
        .eq("user_id", myId)
        .single();
      await client
        .from("wallet")
        .update({
          dummy_token: (wallet?.dummy_token || 0) + payout,
          updated_at: new Date().toISOString(),
        })
        .eq("user_id", myId);
      return payout;
    }
    if (result === "draw") {
      const { data: wallet } = await client
        .from("wallet")
        .select("dummy_token")
        .eq("user_id", myId)
        .single();
      await client
        .from("wallet")
        .update({
          dummy_token: (wallet?.dummy_token || 0) + match.entry_fee,
          updated_at: new Date().toISOString(),
        })
        .eq("user_id", myId);
    }
    return 0;
  }
  function cleanup() {
    if (channel) client.removeChannel(channel);
  }
  return { init, send, onMessage, finish, cleanup, get match() { return match; } };
})();
function hashString(str) {
  let h = 0;
  for (let i = 0; i < str.length; i++) h = (h * 31 + str.charCodeAt(i)) >>> 0;
  return h;
}

// Deterministic PRNG (mulberry32) — used so both players in a live match
// generate the exact same puzzle/sequence/word without any extra network
// round trip. Seed it from the match id (+ an optional salt per game).
function makeRng(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function matchRng(salt) {
  const id = (MatchRoom.match && MatchRoom.match.id) || "seed";
  return makeRng(hashString(id + (salt || "")));
}

// Generic judge for "race" style games — both players play an identical
// (seeded) challenge independently and report a single finishing metric.
// higherIsBetter=false means lowest metric (e.g. time in ms) wins.
function createRaceJudge(stageEl, higherIsBetter, fmt) {
  let mine = null;
  let theirs = null;
  let done = false;
  function note(text) {
    let el = document.getElementById("race-wait-note");
    if (!el) {
      el = document.createElement("p");
      el.id = "race-wait-note";
      el.className = "subtitle";
      stageEl.appendChild(el);
    }
    el.textContent = text;
  }
  function check() {
    if (done || mine === null || theirs === null) return;
    done = true;
    let result;
    if (mine === theirs) result = "draw";
    else if (higherIsBetter) result = mine > theirs ? "win" : "lose";
    else result = mine < theirs ? "win" : "lose";
    showResult(stageEl, result, { mine: fmt(mine), theirs: fmt(theirs) });
  }
  MatchRoom.onMessage("race_finish", (data) => {
    theirs = data.metric;
    if (mine === null) note("Opponent finished \u2014 your turn to complete it!");
    check();
  });
  return {
    finish(metric) {
      if (mine !== null) return;
      mine = metric;
      MatchRoom.send("race_finish", { metric });
      if (theirs === null) note("Waiting for opponent to finish...");
      check();
    },
  };
}

// Small confetti burst used to celebrate a win, both in live matches
// (via showResult) and bot matches (via dashboard.js's endDuel).
function celebrateWin(container) {
  if (!container) return;
  const layer = document.createElement("div");
  layer.className = "confetti-layer";
  const colors = ["#00e701", "#38bdf8", "#f59e0b", "#f16464", "#a78bfa"];
  for (let i = 0; i < 60; i++) {
    const piece = document.createElement("span");
    piece.className = "confetti-piece";
    piece.style.left = Math.random() * 100 + "%";
    piece.style.background = colors[i % colors.length];
    piece.style.animationDelay = Math.random() * 0.4 + "s";
    piece.style.animationDuration = 1.6 + Math.random() * 1.2 + "s";
    piece.style.transform = "rotate(" + Math.floor(Math.random() * 360) + "deg)";
    layer.appendChild(piece);
  }
  container.appendChild(layer);
  setTimeout(() => layer.remove(), 3000);
}
async function showResult(stageEl, result, detail) {
  const payout = await MatchRoom.finish(result);
  const label = result === "win" ? "You won!" : result === "lose" ? "You lost" : "Draw";
  const cls = result === "win" ? "win" : result === "lose" ? "lose" : "draw";
  const tokenLine =
    result === "win"
      ? `<p>+${formatRupees(payout)}</p>`
      : result === "draw"
      ? `<p>Entry fee refunded</p>`
      : `<p>-${formatRupees(MatchRoom.match.entry_fee)}</p>`;
  const detailLine = detail
    ? `<p class="subtitle">You: ${detail.mine} · Opponent: ${detail.theirs}</p>`
    : "";
  stageEl.innerHTML = `
    <p class="result-banner ${cls}">${label}</p>
    ${detailLine}
    ${tokenLine}
    <a href="dashboard.html" class="btn">Back to Lobby</a>
  `;
  if (result === "win") celebrateWin(stageEl);
}
function formatRupees(amount) {
  const n = Number(amount) || 0;
  return "\u20b9" + n.toLocaleString("en-IN");
}
