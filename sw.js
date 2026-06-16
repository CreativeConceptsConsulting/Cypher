// CYPHER Service Worker v5 — cache busting + push notification handler
const CACHE = 'cypher-v5';

self.addEventListener('message', e => {
  if (e.data?.type === 'SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('install', () => { self.skipWaiting(); });

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  // Matches '/', any subpath root like '/cypher/', and any path ending in 'index.html' —
  // not just an exact '/' or '/index.html'. The previous exact-match check only ever
  // matched a root-level deployment; on GitHub Pages project sites (served from
  // '/reponame/' rather than '/'), a fetch to that bare path would fall through to the
  // cache-first branch below instead of being treated as HTML that must never be served stale.
  const isNavOrHTML =
    e.request.mode === 'navigate' ||
    url.pathname.endsWith('/') ||
    url.pathname.endsWith('/index.html');

  if (isNavOrHTML) {
    e.respondWith(
      fetch(e.request, {
        cache: 'no-store',
        headers: { 'Cache-Control': 'no-cache, no-store, must-revalidate', Pragma: 'no-cache' }
      }).catch(() => caches.match('/index.html'))
    );
    return;
  }

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

// ── PUSH NOTIFICATION HANDLER ─────────────────────────────────────────────────
self.addEventListener('push', e => {
  if (!e.data) return;
  let payload = { title: 'CYPHER', body: 'You have a new update', icon: '/icon-192.png', badge: '/icon-192.png', tag: 'cypher-notif', data: {} };
  try { Object.assign(payload, e.data.json()); } catch(err) { payload.body = e.data.text(); }

  e.waitUntil(
    self.registration.showNotification(payload.title, {
      body: payload.body,
      icon: payload.icon || '/icon-192.png',
      badge: payload.badge || '/icon-192.png',
      tag: payload.tag || 'cypher-notif',
      renotify: true,
      data: payload.data || {},
      actions: payload.actions || []
    })
  );
});

// ── NOTIFICATION CLICK HANDLER ────────────────────────────────────────────────
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const target = e.notification.data?.url || '/';
  e.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clientList => {
      // Focus existing window if open
      for (const client of clientList) {
        if (client.url.includes(self.location.origin) && 'focus' in client) {
          client.postMessage({ type: 'NOTIFICATION_CLICK', data: e.notification.data });
          return client.focus();
        }
      }
      // Open new window if none found
      if (clients.openWindow) return clients.openWindow(target);
    })
  );
});
