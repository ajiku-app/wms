// ============================================================
// APP SHELL — sidebar, routing antar halaman, dan penggabungan
// semua modul "views/*.js". Ini titik masuk aplikasi (dipanggil
// dari index.html).
// ============================================================
import { auth, api, subscribeChanges, appVersion } from './api.js';
import { $, modal, pgRefresh, esc } from './ui.js';
import * as Auth from './auth.js';
import { loadMe, renderLogin, renderPendingRole } from './auth.js';

import { renderDashboard, registerDashboardActions } from './views/dashboard.js';
import { renderPackingList, registerPackingListActions } from './views/packinglist.js';
import { renderInbound, registerInboundActions } from './views/inbound.js';
import { renderOutbound, registerOutboundActions } from './views/outbound.js';
import { renderMutasi, registerMutasiActions } from './views/mutasi.js';
import { renderStok, registerStokActions } from './views/stok.js';
import { renderOpname, registerOpnameActions } from './views/opname.js';
import { renderAdjust, registerAdjustActions } from './views/adjust.js';
import { renderMProduk, renderMRak, renderMPemasok, renderMCust, registerMasterActions } from './views/master.js';
import { renderUsers, registerUsersActions } from './views/users.js';
import { renderReport } from './views/report.js';
import { renderActivity } from './views/activity.js';
import { registerLabelActions } from './views/label.js';
import { renderPutaway, registerPutawayActions } from './views/putaway.js';
import { renderKartu } from './views/kartu.js';
import { renderHold, registerHoldActions } from './views/hold.js';
import { renderAging, registerAgingActions } from './views/aging.js';
import { renderRackLabel, registerRackLabelActions } from './views/racklabel.js';

const root = $('#root');
let me = null, viewRole = null; // viewRole: pratinjau menu per peran (hanya tampilan; backend tetap menegakkan hak akses)
const rl = () => viewRole || me.role;
const TTL = { dash: ['Dashboard', ''], stok: ['Informasi stok', ''], put: ['Putaway', ''], kartu: ['Kartu stok', ''], hold: ['Hold dan karantina', ''], rkLabel: ['Label rak', 'Dipertahankan'], aging: ['Laporan aging dan ED', ''] }; // profil pengguna login (name/role/active), diisi ulang tiap boot()

let cur = 'dash', W = null, open = new Set(['Packing List']);
const A = {}; // aksi tombol: data-a="xxx" -> A.xxx(value)
A.mx = () => { $('#mod').innerHTML = ''; };
A.back = () => go(cur);
A.openW = (w) => go(cur, w);
A.newW = () => go(cur, 'new');
const back = `<button class="btn o" data-a="back">← Kembali</button>`;

const CAN = {
  dash: () => true,
  pl: () => ['inbound', 'admin', 'supervisor'].includes(rl()),
  in: () => ['inbound', 'admin', 'supervisor'].includes(rl()),
  out: () => ['picker', 'admin', 'supervisor'].includes(rl()),
  mut: () => ['inbound', 'admin', 'supervisor'].includes(rl()),
  stok: () => true,
  put: () => ['inbound', 'admin', 'supervisor'].includes(rl()),
  kartu: () => ['admin', 'supervisor'].includes(rl()),
  hold: () => ['admin', 'supervisor'].includes(rl()),
  aging: () => true,
  rkLabel: () => ['inbound', 'admin', 'supervisor'].includes(rl()),
  opn: () => ['admin', 'supervisor'].includes(rl()),
  adj: () => ['admin', 'supervisor'].includes(rl()),
  mProduk: () => ['admin', 'supervisor'].includes(rl()),
  mRak: () => ['admin', 'supervisor'].includes(rl()),
  mPemasok: () => ['inbound', 'admin', 'supervisor'].includes(rl()),
  mCust: () => ['picker', 'admin', 'supervisor'].includes(rl()),
  users: () => ['admin', 'supervisor'].includes(rl()),
  rLog: () => ['admin', 'supervisor'].includes(rl()),
  activity: () => true, // semua role yang sudah login boleh lihat (dibatasi ke baris sendiri di backend kecuali admin/supervisor)
};
const MENU = [
  ['dash', 'Dashboard', '⌂'],
  { t: 'Packing List', i: '☰', c: [['pl', 'Pemasok']] },
  { t: 'Inbound', i: '⇩', c: [['in', 'Pemasok'], ['put', 'Putaway']] },
  { t: 'Outbound', i: '⇧', c: [['out', 'Manual']] },
  { t: 'Mutasi', i: '⇄', c: [['mut', 'Pindah Rak']] },
  { t: 'Stok', i: '▣', c: [['stok', 'Informasi Stok'], ['kartu', 'Kartu Stok'], ['hold', 'Hold & Karantina'], ['opn', 'Stok Opname'], ['adj', 'Penyesuaian Stok']] },
  { t: 'Master', i: '▤', c: [['mProduk', 'Produk'], ['mRak', 'Rak'], ['rkLabel', 'Label Rak'], ['mPemasok', 'Pemasok'], ['mCust', 'Customer']] },
  ['users', 'Users Management', '☺'],
  { t: 'Report', i: '↗', c: [['rLog', 'Riwayat Transaksi'], ['aging', 'Laporan Aging & ED'], ['activity', 'Riwayat Aktivitas']] },
];
const NAME = {}, GRP = {};
MENU.forEach(m => m.c ? m.c.forEach(c => { NAME[c[0]] = c[1]; GRP[c[0]] = m.t; }) : NAME[m[0]] = m[1]);

const R = {
  dash: () => renderDashboard(),
  pl: () => renderPackingList(go, W, back),
  in: () => renderInbound(go, W, back),
  out: () => renderOutbound(go, W, back),
  mut: () => renderMutasi(),
  stok: () => renderStok(),
  put: () => renderPutaway(),
  kartu: () => renderKartu(),
  hold: () => renderHold(),
  aging: () => renderAging(),
  rkLabel: () => renderRackLabel(),
  opn: () => renderOpname(go, W, back),
  adj: () => renderAdjust(),
  mProduk: () => renderMProduk(), mRak: () => renderMRak(), mPemasok: () => renderMPemasok(), mCust: () => renderMCust(),
  users: () => renderUsers(),
  rLog: () => renderReport(),
  activity: () => renderActivity(),
};
registerPackingListActions(A, go);
registerInboundActions(A, go);
registerOutboundActions(A, go);
registerMutasiActions(A, go);
registerOpnameActions(A, go);
registerAdjustActions(A, go);
registerMasterActions(A, go);
registerUsersActions(A, go);
registerLabelActions(A);
registerDashboardActions(A);
registerStokActions(A);
registerPutawayActions(A, go);
registerHoldActions(A, go);
registerAgingActions(A);
registerRackLabelActions(A);

function nav() {
  $('#nav').innerHTML = MENU.filter(m => m.c ? m.c.some(c => CAN[c[0]]()) : CAN[m[0]]())
    .map(m => m.c
      ? `<button class="m ${GRP[cur] === m.t ? 'on' : ''}" data-nv="${esc(m.t)}"><i>${esc(m.i)}</i>${esc(m.t)}<s>${open.has(m.t) ? '▲' : '▼'}</s></button>${open.has(m.t) ? `<div class="c">${m.c.filter(c => CAN[c[0]]()).map(c => `<button data-np="${esc(c[0])}" class="${c[0] === cur ? 'on' : ''}">${esc(c[1])}</button>`).join('')}</div>` : ''}`
      : `<button class="m ${m[0] === cur ? 'on' : ''}" data-np="${esc(m[0])}"><i>${esc(m[2])}</i>${esc(m[1])}</button>`)
    .join('');
  const t = TTL[cur] || [GRP[cur] && GRP[cur] !== NAME[cur] ? GRP[cur] + ' — ' + NAME[cur] : (NAME[cur] || 'Dashboard'), ''];
  $('#ttl').textContent = t[0]; document.title = t[0] + ' — WMS FG Warehouse';
  const bd = $('#bdg'); bd.textContent = t[1]; bd.style.display = t[1] ? '' : 'none';
  $('#nav').onclick = (e) => {
    const b = e.target.closest('button'); if (!b) return;
    if (b.dataset.nv) { open.has(b.dataset.nv) ? open.delete(b.dataset.nv) : open.add(b.dataset.nv); nav(); }
    else if (b.dataset.np) { go(b.dataset.np); drawer(false); }
  };
}

// ===== Routing URL: #/<halaman> atau #/<halaman>/<no-dokumen|new>. Hanya nama halaman yang terdaftar (R) yang diterima =====
const ROUTE = /^#\/([A-Za-z][A-Za-z0-9]{0,24})(?:\/([A-Za-z0-9._-]{1,60}))?$/;
const parseRoute = () => { const m = ROUTE.exec(location.hash); return m && Object.hasOwn(R, m[1]) ? [m[1], m[2] || null] : ['dash', null]; };
function syncUrl(p, w, replace) {
  const h = '#/' + p + (typeof w === 'string' && /^[A-Za-z0-9._-]{1,60}$/.test(w) ? '/' + w : '');
  if (location.hash !== h) history[replace ? 'replaceState' : 'pushState'](null, '', h);
}
addEventListener('hashchange', () => { if ($('#nav')) go(...parseRoute(), true); }); // tombol back/forward atau URL diubah manual

function go(p, w = null, replace = false) {
  if (!Object.hasOwn(CAN, p) || !CAN[p]()) { p = 'dash'; w = null; replace = true; } // halaman tak dikenal / tanpa hak akses -> dashboard
  syncUrl(p, w, replace);
  cur = p; W = w; epoch++; dirty = false;
  if (GRP[p]) open.add(GRP[p]);
  nav();
  R[p]().catch(e => { console.error(e); $('#main').innerHTML = '<div class="card">Gagal memuat data. Coba lagi.</div>'; });
  scrollTo(0, 0);
}

// ===== AUTO REFRESH (Supabase Realtime) =====
// Perubahan di database -> tandai "pend". Setiap 1,5 dtk, bila pengguna tidak sedang mengetik / membuka
// dialog / mengisi form, halaman aktif dimuat ulang di latar belakang lalu ditukar (tanpa berkedip);
// posisi scroll, pencarian dan halaman tabel dipertahankan.
let epoch = 0, dirty = false, pend = false, busy = false, unsub = null, tmr = null;
document.addEventListener('input', (e) => {
  const t = e.target; if (!t.closest || !t.closest('#main')) return;
  if (t.classList.contains('sr') || ['q', 'fs', 'fl', 'ag', 'kp', 'rkL', 'rkA', 'rkB'].includes(t.id)) return; // pencarian/filter aman
  dirty = true;
}, true);
function userBusy() {
  const a = document.activeElement, tg = a && a.tagName;
  return $('#mod').innerHTML.trim() !== '' || !!document.getElementById('dlg') || W === 'new' || dirty || document.hidden || busy
    || !!(a && ['INPUT', 'TEXTAREA', 'SELECT'].includes(tg) && a.closest('#main'));
}
async function refreshNow() {
  busy = true; pend = false;
  const ep = epoch, old = $('#main'), y = scrollY;
  const snap = { ids: {}, sr: [...old.querySelectorAll('.sr')].map(i => i.value), pg: [...old.querySelectorAll('.wrap[data-pg]')].map(w => ({ p: w._page, q: w._q || '' })) };
  old.querySelectorAll('input[id],select[id]').forEach(e => { snap.ids[e.id] = e.value; });
  const nu = old.cloneNode(false); nu.innerHTML = ''; nu.style.display = 'none'; old.id = 'main_old'; old.after(nu);
  try { await R[cur](); } catch (e) { console.error(e); nu.remove(); old.id = 'main'; busy = false; return; }
  if (ep === epoch) {
    Object.entries(snap.ids).forEach(([id, val]) => { const e = document.getElementById(id); if (e && e.value !== val) { e.value = val; e.dispatchEvent(new Event('input', { bubbles: true })); e.dispatchEvent(new Event('change', { bubbles: true })); } });
    nu.querySelectorAll('.sr').forEach((i, k) => { if (snap.sr[k] !== undefined) i.value = snap.sr[k]; });
    nu.querySelectorAll('.wrap[data-pg]').forEach((w, k) => { const st = snap.pg[k]; if (st) { w._q = st.q; w._page = st.p; pgRefresh(w); } });
  }
  nu.style.display = ''; old.remove(); scrollTo(0, y); busy = false;
  const d = $('#live'); if (d) { d.classList.add('ping'); setTimeout(() => d.classList.remove('ping'), 900); }
}
function stopLive() { if (unsub) { unsub(); unsub = null; } clearInterval(tmr); tmr = null; }
function startLive() {
  stopLive();
  unsub = subscribeChanges(() => { pend = true; }, (st) => {
    const d = $('#live'); if (!d) return;
    d.classList.toggle('on', st === 'SUBSCRIBED');
    d.title = st === 'SUBSCRIBED' ? 'Auto refresh aktif' : 'Auto refresh: ' + st;
  });
  tmr = setInterval(() => { if (pend && !userBusy()) refreshNow(); }, 1500);
}

function drawer(open) { $('#side').classList.toggle('hide', !open); $('#scrim').style.display = open ? 'block' : 'none'; }
function theme(t) { document.documentElement.dataset.theme = t; try { localStorage.setItem('wms_theme', t); } catch (e) {} }
try { document.documentElement.dataset.theme = localStorage.getItem('wms_theme') === 'light' ? 'light' : 'dark'; } catch (e) { document.documentElement.dataset.theme = 'dark'; }

function renderShell() {
  const ROLES = [['inbound', 'Inbound'], ['picker', 'Picker'], ['admin', 'Admin'], ['supervisor', 'Supervisor']];
  const canPreview = ['admin', 'supervisor'].includes(me.role);
  root.innerHTML = `<div class="app"><div id="scrim"></div><aside id="side" class="hide"><div class="brand"><img class="bl" src="img/logo.svg" alt="WMS"><div class="bt"><span class="w">WMS</span><span class="f">FG Warehouse</span></div></div><div id="nav"></div>
  <div class="sf"><span class="av">${esc((me.name || '?')[0].toUpperCase())}</span><div><b>${esc(me.name)}</b><small>${esc(me.role)}</small></div><button class="btn o s" id="lo">Keluar</button></div></aside>
  <div class="mainw"><div class="top"><button id="tg" aria-label="Menu">☰</button><h2 id="ttl"></h2><span class="bdg" id="bdg"></span><span id="live" title="Auto refresh: menghubungkan…"></span>
  <div class="u"><label class="pr">Peran<select id="rp" ${canPreview ? '' : 'disabled'} title="${canPreview ? 'Pratinjau menu per peran (hak akses tetap dicek server)' : 'Peran akun Anda'}">${ROLES.map(r => `<option value="${esc(r[0])}" ${r[0] === me.role ? 'selected' : ''}>${esc(r[1])}</option>`).join('')}</select></label><button class="btn o" id="th">Tema</button></div></div><main id="main"></main></div></div>
  <div id="mod"></div>`;
  $('#lo').onclick = () => auth.signOut();
  appVersion().then(v => { const b = $('.brand'); if (v && b) b.insertAdjacentHTML('beforeend', `<small>Versi ${esc(v)}</small>`); });
  $('#tg').onclick = () => drawer($('#side').classList.contains('hide'));
  $('#scrim').onclick = () => drawer(false);
  $('#th').onclick = () => theme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark');
  $('#rp').onchange = (e) => { viewRole = e.target.value === me.role ? null : e.target.value; nav(); go(cur); };
  document.body.onclick = (e) => { const b = e.target.closest('[data-a]'); if (b && Object.hasOwn(A, b.dataset.a)) A[b.dataset.a](b.dataset.v); };
  nav(); go(...parseRoute(), true); startLive();
}

export async function boot() {
  const session = await auth.getSession();
  if (!session) { renderLogin(root, boot); return; }
  await loadMe(session);
  me = Auth.ME; // live binding: sudah terisi setelah loadMe() selesai
  if (!rl() || !me.active) { renderPendingRole(root); return; }
  renderShell();
}

auth.onChange((ev) => { if (ev === 'SIGNED_OUT') { stopLive(); history.replaceState(null, '', location.pathname + location.search); renderLogin(root, boot); } });
