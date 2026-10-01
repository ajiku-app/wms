// Service worker: membuat aplikasi bisa di-install (PWA) & memuat cepat.
// Data Supabase TIDAK pernah di-cache (selalu langsung ke jaringan).
const VERSION = 'wms-v4';
const SHELL = `${VERSION}-shell`;
const LIB = `${VERSION}-lib`;
const SHELL_FILES = [
  './', './index.html', './manifest.webmanifest', './css/style.css',
  './img/logo.svg', './img/favicon.svg', './img/icon-192.png', './img/icon-512.png',
  './js/config.js', './js/api.js', './js/ui.js', './js/auth.js', './js/app.js', './js/app-entry.js'
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(SHELL).then(c => c.addAll(SHELL_FILES)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => !k.startsWith(VERSION)).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.hostname.endsWith('.supabase.co')) return; // data & auth: jangan di-cache

  // Library CDN & font: stale-while-revalidate
  if (url.origin !== location.origin) {
    if (!/esm\.sh|cdnjs\.cloudflare\.com|fonts\.(googleapis|gstatic)\.com/.test(url.hostname)) return;
    e.respondWith(caches.open(LIB).then(async c => {
      const hit = await c.match(req);
      const net = fetch(req).then(r => { if (r.ok || r.type === 'opaque') c.put(req, r.clone()); return r; }).catch(() => hit);
      return hit || net;
    }));
    return;
  }

  // File aplikasi: jaringan dulu (selalu versi terbaru), cache jika offline
  e.respondWith(
    fetch(req)
      .then(r => { if (r.ok) caches.open(SHELL).then(c => c.put(req, r.clone())); return r; })
      .catch(() => caches.match(req).then(h => h || (req.mode === 'navigate' ? caches.match('./index.html') : Response.error())))
  );
});
