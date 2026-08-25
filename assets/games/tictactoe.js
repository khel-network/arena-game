function initTicTacToe(stageEl, iAmPlayer1) {
  // Inject styles once
  if (!document.getElementById("ttt-styles")) {
    const style = document.createElement("style");
    style.id = "ttt-styles";
    style.textContent = `
      .ttt-wrapper {
        position: relative;
        width: 300px;
        height: 300px;
        margin: 0 auto;
      }
      .ttt-board {
        display: grid;
        grid-template-columns: repeat(3, 100px);
        grid-template-rows: repeat(3, 100px);
        width: 300px;
        height: 300px;
      }
      .ttt-cell {
        background: #cfe4f2;
        border: 2px solid #555;
        display: flex;
        align-items: center;
        justify-content: center;
        font-size: 48px;
        font-weight: bold;
        cursor: pointer;
        user-select: none;
        box-sizing: border-box;
        color: #222;
      }
      .ttt-cell.filled { cursor: default; }
      .ttt-line-overlay {
        position: absolute;
        top: 0;
        left: 0;
        width: 300px;
        height: 300px;
        pointer-events: none;
      }
      .ttt-winline {
        stroke: #e63946;
        stroke-width: 6;
        stroke-linecap: round;
      }
    `;
    document.head.appendChild(style);
  }

  const mySymbol = iAmPlayer1 ? "X" : "O";
  const theirSymbol = iAmPlayer1 ? "O" : "X";
  let board = Array(9).fill(null);
  let myTurn = iAmPlayer1;
  let over = false;

  const WIN_LINES = [
    [0, 1, 2], [3, 4, 5], [6, 7, 8],
    [0, 3, 6], [1, 4, 7], [2, 5, 8],
    [0, 4, 8], [2, 4, 6],
  ];

  render();

  function render() {
    stageEl.innerHTML = `
      <p class="subtitle">You are <strong>${mySymbol}</strong></p>
      <p class="loading-text" id="turn-label">${myTurn ? "Your move" : "Opponent's move"}</p>
      <div class="ttt-wrapper">
        <div class="ttt-board" id="board"></div>
        <svg class="ttt-line-overlay" id="ttt-line" viewBox="0 0 300 300"></svg>
      </div>
    `;
    const boardEl = document.getElementById("board");
    board.forEach((val, i) => {
      const cell = document.createElement("div");
      cell.className = "ttt-cell" + (val ? " filled" : "");
      cell.textContent = val || "";
      cell.addEventListener("click", () => handleClick(i));
      boardEl.appendChild(cell);
    });
  }

  function handleClick(i) {
    if (over || !myTurn || board[i]) return;
    playMove(i, mySymbol);
    MatchRoom.send("ttt_move", { index: i });
  }

  MatchRoom.onMessage("ttt_move", (data) => {
    playMove(data.index, theirSymbol);
  });

  function playMove(index, symbol) {
    board[index] = symbol;
    myTurn = symbol !== mySymbol;
    render();
    checkEnd();
  }

  function checkEnd() {
    const winner = WIN_LINES.find(
      (line) => board[line[0]] && board[line[0]] === board[line[1]] && board[line[1]] === board[line[2]]
    );
    if (winner) {
      over = true;
      drawWinLine(winner);
      const winSymbol = board[winner[0]];
      setTimeout(() => {
        showResult(stageEl, winSymbol === mySymbol ? "win" : "lose");
      }, 600);
      return;
    }
    if (board.every((c) => c)) {
      over = true;
      showResult(stageEl, "draw");
    }
  }

  function drawWinLine(line) {
    const svg = document.getElementById("ttt-line");
    if (!svg) return;
    const centers = [
      [50, 50], [150, 50], [250, 50],
      [50, 150], [150, 150], [250, 150],
      [50, 250], [150, 250], [250, 250],
    ];
    const [x1, y1] = centers[line[0]];
    const [x2, y2] = centers[line[2]];
    const path = document.createElementNS("http://www.w3.org/2000/svg", "line");
    path.setAttribute("x1", x1);
    path.setAttribute("y1", y1);
    path.setAttribute("x2", x1);
    path.setAttribute("y2", y1);
    path.setAttribute("class", "ttt-winline");
    svg.appendChild(path);
    requestAnimationFrame(() => {
      path.style.transition = "x2 0.4s ease, y2 0.4s ease";
      path.setAttribute("x2", x2);
      path.setAttribute("y2", y2);
    });
  }
}
