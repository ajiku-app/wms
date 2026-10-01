// Jembatan aman: frontend hanya boleh baca/tulis penyimpanan sesi lewat 3 fungsi ini.
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('desktopStore', {
  version: () => ipcRenderer.invoke('app:version'),
  get: k => ipcRenderer.invoke('store:get', k),
  set: (k, v) => ipcRenderer.invoke('store:set', k, v),
  remove: k => ipcRenderer.invoke('store:remove', k)
});
