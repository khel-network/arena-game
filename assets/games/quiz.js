const QUIZ_POOL = [
  { q: "What is the capital of Japan?", options: ["Seoul", "Tokyo", "Beijing", "Bangkok"], correct: 1 },
  { q: "How many continents are there?", options: ["5", "6", "7", "8"], correct: 2 },
  { q: "What is the largest planet?", options: ["Earth", "Mars", "Jupiter", "Saturn"], correct: 2 },
  { q: "Who wrote Romeo and Juliet?", options: ["Dickens", "Shakespeare", "Austen", "Twain"], correct: 1 },
  { q: "What is H2O commonly known as?", options: ["Salt", "Oxygen", "Water", "Hydrogen"], correct: 2 },
  { q: "How many players on a football team?", options: ["9", "10", "11", "12"], correct: 2 },
  { q: "What is the fastest land animal?", options: ["Lion", "Cheetah", "Horse", "Leopard"], correct: 1 },
  { q: "Which planet is known as the Red Planet?", options: ["Venus", "Mars", "Jupiter", "Mercury"], correct: 1 },
  { q: "What is the smallest prime number?", options: ["0", "1", "2", "3"], correct: 2 },
  { q: "How many strings does a standard guitar have?", options: ["4", "5", "6", "7"], correct: 2 },
];

function seededShuffle(arr, seed) {
  const a = [...arr];
  let s = seed;
  for (let i = a.length - 1; i > 0; i--) {
    s = (s * 9301 + 49297) % 233280;
    const j = Math.floor((s / 233280) * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

function initQuizBattle(stageEl, iAmPlayer1, matchId) {
  const seed = hashString(matchId);
  const questions = seededShuffle(QUIZ_POOL, seed).slice(0, 5);

  let qIndex = 0;
  let myScore = 0;
  let opponentScore = 0;
  let answered = false;
  let questionStart = 0;

  showQuestion();

  function showQuestion() {
    if (qIndex >= questions.length) return finishQuiz();

    answered = false;
    questionStart = performance.now();
    const q = questions[qIndex];

    stageEl.innerHTML = `
      <div class="score-row">
        <span class="me">You: ${myScore}</span>
        <span>Opponent: ${opponentScore}</span>
      </div>
      <p class="loading-text">Question ${qIndex + 1} of ${questions.length}</p>
      <p class="quiz-question">${q.q}</p>
      <div class="quiz-options" id="options"></div>
    `;

    const optsEl = document.getElementById("options");
    q.options.forEach((opt, i) => {
      const btn = document.createElement("div");
      btn.className = "quiz-option";
      btn.textContent = opt;
      btn.addEventListener("click", () => selectAnswer(i));
      optsEl.appendChild(btn);
    });
  }

  function selectAnswer(i) {
    if (answered) return;
    answered = true;
    const q = questions[qIndex];
    const correct = i === q.correct;
    const timeMs = performance.now() - questionStart;

    document.querySelectorAll(".quiz-option").forEach((el, idx) => {
      if (idx === q.correct) el.classList.add("correct");
      else if (idx === i) el.classList.add("wrong");
    });

    if (correct) {
      myScore += 1;
      MatchRoom.send("quiz_point", { qIndex, timeMs });
    }

    setTimeout(nextQuestion, 900);
  }

  MatchRoom.onMessage("quiz_point", (data) => {
    if (data.qIndex >= qIndex) opponentScore += 1;
  });

  function nextQuestion() {
    qIndex += 1;
    showQuestion();
  }

  function finishQuiz() {
    let result;
    if (myScore > opponentScore) result = "win";
    else if (myScore < opponentScore) result = "lose";
    else result = "draw";

    showResult(stageEl, result, { mine: `${myScore} pts`, theirs: `${opponentScore} pts` });
  }
}
