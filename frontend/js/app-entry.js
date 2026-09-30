import { boot } from './app.js';
boot();

// PWA: daftarkan service worker agar aplikasi bisa di-install (Chrome/Edge)
if ('serviceWorker' in navigator && location.protocol !== 'file:') {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('sw.js').catch(e => console.warn('SW gagal:', e));
  });
}
