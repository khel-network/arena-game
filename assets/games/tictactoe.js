function initTicTacToe(stageEl, iAmPlayer1) {
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
      <div class="ttt-board" id="board"></div>
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
      const winSymbol = board[winner[0]];
      showResult(stageEl, winSymbol === mySymbol ? "win" : "lose");
      return;
    }

    if (board.every((c) => c)) {
      over = true;
      showResult(stageEl, "draw");
    }
  }
}
