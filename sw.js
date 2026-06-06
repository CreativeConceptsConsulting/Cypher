// CYPHER Service Worker — forces fresh index.html on every load
// Caches static assets for performance, never caches index.html

const CACHE = 'cypher-v2';
const NEVER_CACHE = ['/', '/index.html'];

// Immediately take control when a new version installs
self.addEventListener('message', e => {
  if (e.data?.type === 'SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  // Delete old caches when a new version activates
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);

  // index.html — always fetch fresh, never serve from cache
  const isHTML = NEVER_CACHE.some(p => url.pathname === p || url.pathname.endsWith('/index.html'))
    || e.request.mode === 'navigate';

  if (isHTML) {
    e.respondWith(
      fetch(e.request, { cache: 'no-store' })
        .catch(() => caches.match('/index.html')) // fallback to cached if offline
    );
    return;
  }

  // Static assets (fonts, CDN scripts) — cache-first for speed
  if (e.request.method === 'GET') {
    e.respondWith(
      caches.match(e.request).then(cached => {
        if (cached) return cached;
        return fetch(e.request).then(response => {
          if (response.ok) {
            const clone = response.clone();
            caches.open(CACHE).then(c => c.put(e.request, clone));
          }
          return response;
        });
      })
    );
  }
});
