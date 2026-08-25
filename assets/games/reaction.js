function initReactionDuel(stageEl, iAmPlayer1) {
  stageEl.innerHTML = `
    <p class="loading-text">Waiting for both players to be ready...</p>
    <div class="reaction-pad" id="pad">Get ready...</div>
  `;

  const pad = () => document.getElementById("pad");
  let goTime = null;
  let myTime = null;
  let opponentTime = null;
  let armed = false;

  function startRound() {
    armed = true;
    pad().className = "reaction-pad";
    pad().textContent = "Wait for green...";

    const delay = 1500 + Math.random() * 3000;
    setTimeout(() => {
      if (!armed) return;
      goTime = performance.now();
      pad().className = "reaction-pad go";
      pad().textContent = "CLICK NOW!";
    }, delay);
  }

  stageEl.addEventListener("click", (e) => {
    if (!e.target.closest("#pad") || myTime !== null) return;

    if (!goTime) {
      pad().className = "reaction-pad early";
      pad().textContent = "Too early! You lose this round.";
      myTime = 99999;
      MatchRoom.send("reaction_result", { time: myTime });
      checkOutcome();
      return;
    }

    myTime = performance.now() - goTime;
    pad().textContent = `You: ${myTime.toFixed(0)}ms`;
    MatchRoom.send("reaction_result", { time: myTime });
    checkOutcome();
  });

  MatchRoom.onMessage("reaction_result", (data) => {
    opponentTime = data.time;
    checkOutcome();
  });

  MatchRoom.onMessage("start_round", () => startRound());

  function checkOutcome() {
    if (myTime === null || opponentTime === null) return;

    let result;
    if (myTime < opponentTime) result = "win";
    else if (myTime > opponentTime) result = "lose";
    else result = "draw";

    showResult(stageEl, result, {
      mine: myTime >= 99999 ? "Too early" : `${myTime.toFixed(0)}ms`,
      theirs: opponentTime >= 99999 ? "Too early" : `${opponentTime.toFixed(0)}ms`,
    });
  }

  if (iAmPlayer1) {
    MatchRoom.send("start_round", {});
    startRound();
  }
}
