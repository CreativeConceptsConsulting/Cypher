// CYPHER Service Worker v3 — forces fresh index.html on every load
// Updated: forces cache-bust on all devices

const CACHE = 'cypher-v3';
const NEVER_CACHE = ['/', '/index.html', './index.html'];

// Immediately take control when a new version installs
self.addEventListener('message', e => {
  if (e.data?.type === 'SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('install', () => {
  self.skipWaiting(); // activate immediately
});

self.addEventListener('activate', e => {
  // Delete ALL old caches (including cypher-v2 and any others)
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim()) // take control of all clients immediately
  );
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);

  // index.html and navigation — ALWAYS fetch fresh, no-store, no cache
  const isNavOrHTML =
    e.request.mode === 'navigate' ||
    NEVER_CACHE.some(p => url.pathname === p || url.pathname.endsWith('/index.html'));

  if (isNavOrHTML) {
    e.respondWith(
      fetch(e.request, {
        cache: 'no-store',
        headers: { 'Cache-Control': 'no-cache, no-store, must-revalidate', Pragma: 'no-cache' }
      }).catch(() => caches.match('/index.html'))
    );
    return;
  }

  // Static assets (fonts, CDN) — cache-first for speed
  if (e.request.method === 'GET') {
    e.respondWith(
      caches.match(e.request).then(cached => {
        if (cached) return cached;
        return fetch(e.request).then(response => {
          if (response.ok && response.type !== 'opaque') {
            const clone = response.clone();
            caches.open(CACHE).then(c => c.put(e.request, clone));
          }
          return response;
        });
      })
    );
  }
});
