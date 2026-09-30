// Pembungkus desktop: menyajikan folder frontend lewat server lokal (127.0.0.1)
// agar ES module berjalan (file:// diblokir browser) dan CSP 'self' tetap valid.
const { app, BrowserWindow, shell, Menu, dialog } = require('electron');
const { autoUpdater } = require('electron-updater');
const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = app.isPackaged
  ? path.join(process.resourcesPath, 'frontend')
  : path.join(__dirname, '..', 'frontend');

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.json': 'application/json', '.webmanifest': 'application/manifest+json',
  '.ico': 'image/x-icon', '.woff2': 'font/woff2'
};

// Port TETAP agar origin (http://127.0.0.1:PORT) tidak berubah -> sesi login
// tersimpan di localStorage tetap ada setelah aplikasi ditutup/dibuka lagi.
const PORT = 47653;

function startServer() {
  const server = http.createServer((req, res) => {
    let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (p.endsWith('/')) p += 'index.html';
    const file = path.normalize(path.join(ROOT, p));
    if (!file.startsWith(ROOT)) { res.writeHead(403); return res.end(); }
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404); return res.end('Not found'); }
      res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
      res.end(data);
    });
  });
  return new Promise((resolve, reject) => {
    let port = PORT;
    const tryListen = () => server.listen(port, '127.0.0.1');
    server.on('listening', () => resolve(server.address().port));
    server.on('error', err => {
      if (err.code === 'EADDRINUSE' && port < PORT + 10) { port++; tryListen(); } // cadangan
      else reject(err);
    });
    tryListen();
  });
}

// Auto-update dari GitHub Releases (hanya pada aplikasi hasil install)
function setupAutoUpdate(win) {
  if (!app.isPackaged) return;
  autoUpdater.autoDownload = true;
  autoUpdater.autoInstallOnAppQuit = true;
  autoUpdater.on('update-downloaded', info => {
    dialog.showMessageBox(win, {
      type: 'info', buttons: ['Restart sekarang', 'Nanti'], defaultId: 0, cancelId: 1,
      title: 'Pembaruan tersedia',
      message: `Versi ${info.version} sudah diunduh.`,
      detail: 'Restart untuk memasang pembaruan. Jika memilih "Nanti", pembaruan dipasang otomatis saat aplikasi ditutup.'
    }).then(r => { if (r.response === 0) autoUpdater.quitAndInstall(); });
  });
  autoUpdater.on('error', e => console.warn('Auto-update:', e && e.message));
  const check = () => autoUpdater.checkForUpdates().catch(() => {});
  check();
  setInterval(check, 4 * 60 * 60 * 1000); // cek ulang tiap 4 jam
}

async function createWindow() {
  const port = await startServer();
  const win = new BrowserWindow({
    width: 1366, height: 820, minWidth: 1024, minHeight: 640,
    backgroundColor: '#0a0b0e', title: 'WMS FG Warehouse',
    icon: path.join(__dirname, 'build', 'icon.png'),
    autoHideMenuBar: true,
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true }
  });
  Menu.setApplicationMenu(null);
  // Tautan eksternal dibuka di browser, bukan di jendela aplikasi
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (!url.startsWith(`http://127.0.0.1:${port}`)) shell.openExternal(url);
    return { action: 'deny' };
  });
  win.loadURL(`http://127.0.0.1:${port}/index.html`);
  setupAutoUpdate(win);
}

// Hanya satu jendela aplikasi
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => {
    const [w] = BrowserWindow.getAllWindows();
    if (w) { if (w.isMinimized()) w.restore(); w.focus(); }
  });
  app.whenReady().then(createWindow);
  app.on('window-all-closed', () => app.quit());
}
