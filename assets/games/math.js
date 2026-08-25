function initMathDuel(stageEl, iAmPlayer1, matchId) {
  let round = 0;
  let myWins = 0;
  let opponentWins = 0;
  let roundOver = false;
  let currentAnswer = null;

  nextRound();

  function seededRandom(seed) {
    let s = seed;
    s = (s * 9301 + 49297) % 233280;
    return s / 233280;
  }

  function generateProblem(roundNum) {
    const seed = hashString(matchId) + roundNum * 7919;
    const r1 = seededRandom(seed);
    const r2 = seededRandom(seed + 1);
    const r3 = seededRandom(seed + 2);

    const ops = ["+", "-", "\u00d7"];
    const op = ops[Math.floor(r3 * ops.length)];
    let a = Math.floor(r1 * 20) + 1;
    let b = Math.floor(r2 * 12) + 1;

    if (op === "\u00d7") {
      a = Math.floor(r1 * 9) + 2;
      b = Math.floor(r2 * 9) + 2;
    }
    if (op === "-" && b > a) [a, b] = [b, a];

    const answer = op === "+" ? a + b : op === "-" ? a - b : a * b;
    return { text: `${a} ${op} ${b}`, answer };
  }

  function nextRound() {
    if (round >= 3 || myWins === 2 || opponentWins === 2) return finishMatch();

    roundOver = false;
    const problem = generateProblem(round);
    currentAnswer = problem.answer;

    stageEl.innerHTML = `
      <div class="score-row">
        <span class="me">You: ${myWins}</span>
        <span>Opponent: ${opponentWins}</span>
      </div>
      <p class="loading-text">Round ${round + 1} of 3 - first correct answer wins</p>
      <p class="math-problem">${problem.text} = ?</p>
      <input type="number" class="math-input" id="math-answer" autofocus />
    `;

    const input = document.getElementById("math-answer");
    input.focus();
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") submitAnswer(input.value);
    });
  }

  function submitAnswer(value) {
    if (roundOver) return;
    const num = parseFloat(value);
    if (num === currentAnswer) {
      roundOver = true;
      myWins += 1;
      MatchRoom.send("math_round_won", { round });
      setTimeout(nextRound, 800);
    }
  }

  MatchRoom.onMessage("math_round_won", (data) => {
    if (data.round === round && !roundOver) {
      roundOver = true;
      opponentWins += 1;
      setTimeout(nextRound, 800);
    }
  });

  function finishMatch() {
    let result;
    if (myWins > opponentWins) result = "win";
    else if (myWins < opponentWins) result = "lose";
    else result = "draw";

    showResult(stageEl, result, { mine: `${myWins} rounds`, theirs: `${opponentWins} rounds` });
  }
}
