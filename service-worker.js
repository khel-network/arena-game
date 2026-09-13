/* ============================================================
   SkillClash Service Worker v11
   - Caches the app shell so it opens instantly and works offline
   - Network-first for Supabase / ZapUPI (always fresh)
   - Cache-first for the app shell and icons (fast)
   ============================================================ */

const APP_CACHE = 'skillclash-app-v11';
const RUNTIME_CACHE = 'skillclash-runtime-v11';

const APP_SHELL = [
  '/',
  '/index.html',
  '/manifest.json',
  '/icon-192.png',
  '/icon-512.png'
];

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(APP_CACHE).then((cache) => {
      return cache.addAll(APP_SHELL).catch(() => {});
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

  // Never cache Supabase, ZapUPI, or Google (auth) — always live
  if (
    url.hostname.includes('supabase.co') ||
    url.hostname.includes('zapupi.com') ||
    url.hostname.includes('google') ||
    url.hostname.includes('googleapis.com') ||
    url.hostname.includes('gstatic.com') ||
    url.hostname.includes('dicebear.com') ||
    url.hostname.includes('cdnjs.cloudflare.com') ||
    url.hostname.includes('jsdelivr.net')
  ) {
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
          .catch(() => cached);
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
