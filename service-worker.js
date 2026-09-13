/* ============================================================
   SkillClash Service Worker v13
   - Caches the app shell so it opens instantly and works offline
   - Network-first for Supabase / ZapUPI (always fresh)
   - Cache-first for the app shell and icons (fast)
   - Skips caching for auth/analytics/CDN dynamic content
   ============================================================ */

const APP_CACHE = 'skillclash-app-v13';
const RUNTIME_CACHE = 'skillclash-runtime-v13';

const APP_SHELL = [
  '/',
  '/index.html',
  '/manifest.json',
  '/icon-192.png',
  '/icon-512.png'
];

// Hosts that must NEVER be cached — always live network
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

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(APP_CACHE).then((cache) => {
      return cache.addAll(APP_SHELL).catch((err) => {
        console.warn('[SW] Some shell files failed to pre-cache:', err);
      });
    })
  );
});

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

self.addEventListener('fetch', (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // Ignore non-GET requests
  if (req.method !== 'GET') return;

  // Ignore non-http(s) schemes (chrome-extension, data:, etc.)
  if (!url.protocol.startsWith('http')) return;

  // Never cache auth, payment, realtime, or CDN dynamic content — always live
  if (NETWORK_ONLY_HOSTS.some((h) => url.hostname.includes(h))) {
    return; // let the browser handle these normally
  }

  // Same-origin requests — cache-first with network fallback
  if (url.origin === self.location.origin) {
    event.respondWith(
      caches.match(req).then((cached) => {
        const fetchPromise = fetch(req)
          .then((networkRes) => {
            if (networkRes && networkRes.status === 200 && networkRes.type === 'basic') {
              const copy = networkRes.clone();
              caches.open(RUNTIME_CACHE).then((cache) => cache.put(req, copy));
            }
            return networkRes;
          })
          .catch(() => {
            // Offline: fall back to cached version, or cached index.html for navigation
            if (cached) return cached;
            if (req.mode === 'navigate') {
              return caches.match('/index.html') || caches.match('/');
            }
            return Response.error();
          });
        return cached || fetchPromise;
      })
    );
    return;
  }

  // Everything else — try network, fall back to cache
  event.respondWith(
    fetch(req).catch(() => caches.match(req))
  );
});

// ===== Allow the page to force-activate a new SW version =====
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
