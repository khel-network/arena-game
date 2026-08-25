const ENTRY_FEE = 50;
let queuePollTimer = null;
let queueChannel = null;

async function startRealMatchmaking(gameType, userId, onStatus) {
  onStatus("Deducting entry fee...");

  const { data: wallet } = await client
    .from("wallet")
    .select("dummy_token")
    .eq("user_id", userId)
    .single();

  if (!wallet || wallet.dummy_token < ENTRY_FEE) {
    onStatus("insufficient");
    return;
  }

  await client
    .from("wallet")
    .update({ dummy_token: wallet.dummy_token - ENTRY_FEE, updated_at: new Date().toISOString() })
    .eq("user_id", userId);

  onStatus("Looking for an opponent...");

  const { data: waiting } = await client
    .from("matchmaking_queue")
    .select("user_id, created_at")
    .eq("game_type", gameType)
    .neq("user_id", userId)
    .order("created_at", { ascending: true })
    .limit(1);

  if (waiting && waiting.length > 0) {
    const opponentId = waiting[0].user_id;
    await client.from("matchmaking_queue").delete().eq("user_id", opponentId);

    const { data: match, error } = await client
      .from("matches")
      .insert({
        game_type: gameType,
        player1_id: opponentId,
        player2_id: userId,
        entry_fee: ENTRY_FEE,
      })
      .select()
      .single();

    if (!error && match) {
      window.location.href = `match.html?id=${match.id}&game=${gameType}`;
      return;
    }
  }

  await client.from("matchmaking_queue").upsert({
    user_id: userId,
    game_type: gameType,
  });

  queueChannel = client
    .channel(`queue-watch-${userId}`)
    .on(
      "postgres_changes",
      {
        event: "INSERT",
        schema: "public",
        table: "matches",
        filter: `player2_id=eq.${userId}`,
      },
      (payload) => {
        cleanupMatchmaking();
        window.location.href = `match.html?id=${payload.new.id}&game=${gameType}`;
      }
    )
    .subscribe();

  queuePollTimer = setInterval(async () => {
    const { data: mine } = await client
      .from("matches")
      .select("id")
      .or(`player1_id.eq.${userId},player2_id.eq.${userId}`)
      .eq("status", "active")
      .order("created_at", { ascending: false })
      .limit(1);

    if (mine && mine.length > 0) {
      cleanupMatchmaking();
      window.location.href = `match.html?id=${mine[0].id}&game=${gameType}`;
    }
  }, 2000);
}

function cleanupMatchmaking() {
  if (queuePollTimer) clearInterval(queuePollTimer);
  if (queueChannel) client.removeChannel(queueChannel);
}

async function cancelRealMatchmaking(userId) {
  cleanupMatchmaking();
  await client.from("matchmaking_queue").delete().eq("user_id", userId);

  const { data: wallet } = await client
    .from("wallet")
    .select("dummy_token")
    .eq("user_id", userId)
    .single();

  if (wallet) {
    await client
      .from("wallet")
      .update({ dummy_token: wallet.dummy_token + ENTRY_FEE, updated_at: new Date().toISOString() })
      .eq("user_id", userId);
  }
}
