client.auth.getSession().then(({ data: { session } }) => {
  if (session) window.location.href = "dashboard.html";
});

const loginBtn = document.getElementById("google-login-btn");
loginBtn.addEventListener("click", async () => {
  loginBtn.disabled = true;
  loginBtn.textContent = "Redirecting to Google...";
  const { error } = await client.auth.signInWithOAuth({
    provider: "google",
    options: {
      redirectTo: `${window.location.origin}${window.location.pathname.replace("index.html", "")}dashboard.html`,
    },
  });
  if (error) {
    alert("Login failed: " + error.message);
    loginBtn.disabled = false;
    loginBtn.textContent = "Sign in with Google";
  }
});
