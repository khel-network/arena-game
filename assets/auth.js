// Check for existing session and redirect if already logged in
client.auth.getSession().then(({ data: { session } }) => {
  if (session) {
    window.location.href = "dashboard.html";
  }
});

const googleLoginBtn = document.getElementById("google-login-btn");
const navLoginBtn = document.getElementById("nav-login-btn");
const navSignupBtn = document.getElementById("nav-signup-btn");

async function triggerGoogleLogin() {
  const btn = googleLoginBtn;
  if (btn) {
    btn.disabled = true;
    btn.querySelector("span").textContent = "Connecting to Google...";
  }

  const redirectUrl = `${window.location.origin}${window.location.pathname.replace("index.html", "")}dashboard.html`;

  const { error } = await client.auth.signInWithOAuth({
    provider: "google",
    options: {
      redirectTo: redirectUrl,
    },
  });

  if (error) {
    alert("Login failed: " + error.message);
    if (btn) {
      btn.disabled = false;
      btn.querySelector("span").textContent = "Continue with Google";
    }
  }
}

if (googleLoginBtn) googleLoginBtn.addEventListener("click", triggerGoogleLogin);
if (navLoginBtn) navLoginBtn.addEventListener("click", triggerGoogleLogin);
if (navSignupBtn) navSignupBtn.addEventListener("click", triggerGoogleLogin);
