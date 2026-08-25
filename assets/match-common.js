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

async function showResult(stageEl, result, detail) {
  const payout = await MatchRoom.finish(result);
  const label = result === "win" ? "You won!" : result === "lose" ? "You lost" : "Draw";
  const cls = result === "win" ? "win" : result === "lose" ? "lose" : "draw";
  const tokenLine =
    result === "win"
      ? `<p>+${payout} tokens</p>`
      : result === "draw"
      ? `<p>Entry fee refunded</p>`
      : `<p>-${MatchRoom.match.entry_fee} tokens</p>`;

  const detailLine = detail
    ? `<p class="subtitle">You: ${detail.mine} · Opponent: ${detail.theirs}</p>`
    : "";

  stageEl.innerHTML = `
    <p class="result-banner ${cls}">${label}</p>
    ${detailLine}
    ${tokenLine}
    <a href="dashboard.html" class="btn">Back to Lobby</a>
  `;
}
