// CYPHER Service Worker v5.9.3
// Merged: original fetch strategy (GitHub Pages safe) + full push/click handlers

const CACHE = 'cypher-v5.9.3';

// ── SKIP WAITING ──────────────────────────────────────────────────────────────
self.addEventListener('message', e => {
  if (e.data?.type === 'SKIP_WAITING') self.skipWaiting();
});

// ── INSTALL ───────────────────────────────────────────────────────────────────
self.addEventListener('install', () => { self.skipWaiting(); });

// ── ACTIVATE — purge old caches ───────────────────────────────────────────────
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// ── FETCH ─────────────────────────────────────────────────────────────────────
// Network-first (no-store) for navigation/HTML — never serve stale HTML.
// Handles GitHub Pages project sites served from /reponame/ subpaths.
// Cache-first for all other GET requests (scripts, styles, fonts, images).
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);

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
// Payload format (sent by server Edge Function):
//   { title, body, type, icon, badge, tag, url, actions }
// type values: task_assigned | task_update | task_status |
//              cal_suggestion | suggestion_response | daily_brief | general
self.addEventListener('push', e => {
  if (!e.data) return;

  let payload = {
    title: 'CYPHER',
    body: 'You have a new update.',
    type: 'general',
    icon: './icon-192.png',
    badge: './icon-192.png',
    tag: 'cypher-notif',
    url: './',
    data: {},
    actions: []
  };
  try { Object.assign(payload, e.data.json()); } catch { payload.body = e.data.text(); }

  // Type-specific emoji prefix on the title
  const prefix = {
    task_assigned:       '✅ ',
    task_update:         '📋 ',
    task_status:         '📋 ',
    cal_suggestion:      '📅 ',
    suggestion_response: '🗓️ ',
    daily_brief:         '⚡ ',
    general:             '',
  }[payload.type] || '';

  // High-priority types stay visible until user dismisses them
  const requireInteraction =
    payload.type === 'task_assigned' ||
    payload.type === 'cal_suggestion';

  const options = {
    body:    payload.body,
    icon:    payload.icon  || './icon-192.png',
    badge:   payload.badge || './icon-192.png',
    tag:     payload.tag   || payload.type || 'cypher-notif',
    renotify: true,
    requireInteraction,
    data: {
      url:  payload.url  || './',
      type: payload.type || 'general',
      ...payload.data,
    },
    actions: payload.actions?.length ? payload.actions : [
      { action: 'open',    title: 'Open CYPHER' },
      { action: 'dismiss', title: 'Dismiss' },
    ],
  };

  e.waitUntil(
    self.registration.showNotification(prefix + payload.title, options)
  );
});

// ── NOTIFICATION CLICK HANDLER ────────────────────────────────────────────────
// Focuses existing CYPHER tab or opens a new one.
// Posts NOTIFICATION_CLICK to the app so it can route to the right tab.
self.addEventListener('notificationclick', e => {
  e.notification.close();
  if (e.action === 'dismiss') return;

  const target   = e.notification.data?.url  || './';
  const notifType = e.notification.data?.type || 'general';

  e.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clientList => {
      for (const client of clientList) {
        if (client.url.includes(self.location.origin) && 'focus' in client) {
          // Tell the app which tab to navigate to
          client.postMessage({
            type: 'NOTIFICATION_CLICK',
            notifType,
            data: e.notification.data,
          });
          return client.focus();
        }
      }
      if (clients.openWindow) return clients.openWindow(target);
    })
  );
});
