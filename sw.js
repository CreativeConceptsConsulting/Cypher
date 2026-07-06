// CYPHER Service Worker v5 — cache busting + push notification handler
// FIX (v5): CACHE was a hardcoded literal ('cypher-v4') that never changed
// between releases. index.html correctly cache-busts THIS FILE via
// sw.js?v=X on every ship, but once installed, every asset this SW cached
// (manifest.json, icons, CDN bundles) sat in that same unversioned bucket
// forever — activate() only deletes caches whose name differs from CACHE,
// so nothing was ever actually evicted release over release. Deriving the
// cache name from the same ?v= query param makes each release's assets
// live in their own bucket, so the existing cleanup logic actually works.
const _swVersion = new URL(self.location.href).searchParams.get('v') || 'dev';
const CACHE = 'cypher-' + _swVersion;
// Paths that must always be fetched fresh — never served from cache.
// manifest.json added: it was previously falling through to the generic
// cache-first GET handler below, so a stale manifest (old name/icons/
// start_url) could stick on a device indefinitely.
const NETWORK_FIRST = ['/', '/index.html', '/manifest.json'];

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
  const isNetworkFirst =
    e.request.mode === 'navigate' ||
    NETWORK_FIRST.some(p => url.pathname === p) ||
    url.pathname.endsWith('/index.html') ||
    url.pathname.endsWith('/manifest.json');

  if (isNetworkFirst) {
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
  const _defaultIcon = new URL('icon-192.png', self.location).href;
  let payload = { title: 'CYPHER', body: 'You have a new update', icon: _defaultIcon, badge: _defaultIcon, tag: 'cypher-notif', data: {} };
  try { Object.assign(payload, e.data.json()); } catch(err) { payload.body = e.data.text(); }

  e.waitUntil(
    self.registration.showNotification(payload.title, {
      body: payload.body,
      icon: payload.icon || _defaultIcon,
      badge: payload.badge || _defaultIcon,
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
