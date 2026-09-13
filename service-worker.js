/* ============================================================
   SkillClash Service Worker v13 (offline-fixed)
   - Caches app shell on install
   - Network-first for HTML (so updates land fast)
   - Cache-first for icons/manifest (fast)
   - Serves /offline.html when navigation fails while offline
   - Never caches Supabase / ZapUPI / auth / CDN dynamic
   ============================================================ */

const APP_CACHE = 'skillclash-app-v13';
const RUNTIME_CACHE = 'skillclash-runtime-v13';

const APP_SHELL = [
  '/',
  '/index.html',
  '/offline.html',
  '/manifest.json',
  '/icon-192.png',
  '/icon-512.png'
];

const NETWORK_ONLY_HOSTS = [
  'supabase.co',
  'zapupi.com',
  'zapupi.in',
  'google.com',
  'googleapis.com',
  'gstatic.com',
  'dicebear.com',
  'cdnjs.cloudflare.com',
  'jsdelivr.net',
  'fonts.googleapis.com',
  'fonts.gstatic.com'
];

// ===== Install: pre-cache the shell =====
self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(APP_CACHE).then((cache) => {
      // Cache each file individually so one 404 doesn't break the whole install
      return Promise.all(
        APP_SHELL.map((url) =>
          cache.add(url).catch((err) => {
            console.warn('[SW] Skipped pre-cache:', url, err);
          })
        )
      );
    })
  );
});

// ===== Activate: clean old caches =====
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => {
      return Promise.all(
        keys
          .filter((k) => k !== APP_CACHE && k !== RUNTIME_CACHE)
          .map((k) => caches.delete(k))
      );
    }).then(() => self.clients.claim())
  );
});

// ===== Fetch =====
self.addEventListener('fetch', (event) => {
  const req = event.request;
  const url = new URL(req.url);

  if (req.method !== 'GET') return;
  if (!url.protocol.startsWith('http')) return;

  // Never cache auth / payments / CDNs
  if (NETWORK_ONLY_HOSTS.some((h) => url.hostname.includes(h))) {
    return; // browser handles it directly
  }

  // --- Navigation requests (HTML page loads) ---
  // Network-first so users get the newest index.html when online,
  // fall back to cached index.html (or offline.html) when offline.
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req)
        .then((res) => {
          if (res && res.status === 200) {
            const copy = res.clone();
            caches.open(APP_CACHE).then((c) => c.put('/index.html', copy));
          }
          return res;
        })
        .catch(async () => {
          const cachedIndex = await caches.match('/index.html');
          if (cachedIndex) return cachedIndex;
          const offline = await caches.match('/offline.html');
          if (offline) return offline;
          return new Response('Offline', { status: 503, headers: { 'Content-Type': 'text/plain' } });
        })
    );
    return;
  }

  // --- Same-origin static assets (icons, manifest, etc.) ---
  if (url.origin === self.location.origin) {
    event.respondWith(
      caches.match(req).then((cached) => {
        if (cached) return cached;
        return fetch(req)
          .then((res) => {
            if (res && res.status === 200 && res.type === 'basic') {
              const copy = res.clone();
              caches.open(RUNTIME_CACHE).then((c) => c.put(req, copy));
            }
            return res;
          })
          .catch(() => Response.error());
      })
    );
    return;
  }

  // --- Other cross-origin GETs (shouldn't reach here due to NETWORK_ONLY, but safe) ---
  event.respondWith(
    fetch(req).catch(() => caches.match(req))
  );
});

// ===== Allow page to force-activate a new SW =====
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
