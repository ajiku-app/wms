import { api } from '../api.js';
import { $, T, tag, fmt, modal, days, esc } from '../ui.js';

const HARI = ['Min', 'Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab'];
const WARN = 60, FULL = 90; // ambang okupansi rak (%): kuning >= 60, merah >= 90

let RK = []; // rak aktif dari dashboard terakhir (dipakai popup per blok)
const pct = (u, c) => c > 0 ? Math.round(u / c * 100) : null;
const lvl = (p) => p === null ? 'na' : p >= FULL ? 'full' : p >= WARN ? 'warn' : '';
const ST = { full: 'Penuh', part: 'Tersisa', empty: 'Kosong' };
const stOf = (used, cap) => !(used > 0) ? 'empty' : (cap > 0 && used >= cap) ? 'full' : 'part'; // kosong abu, terisi kuning, penuh merah
const rackTile = (r) => { const s = stOf(r.used, r.capacity); return `<button class="rt ${s}" data-a="rackOpen" data-v="${esc(r.code)}"><b>${esc(r.code)}</b><span>${esc(ST[s])}</span><small>${esc(fmt(r.used || 0) + (r.capacity > 0 ? '/' + fmt(r.capacity) : '') + ' ctn')}</small></button>`; };
const blokOf = (r) => String(r.code).charAt(0).toUpperCase();

export async function renderDashboard() {
  $('#main').innerHTML = '<div class="card">Memuat…</div>';
  const d = await api.dashboard();
  const kpi = (l, v, c = '', t = '') => `<div class="card kpi" title="${esc(t)}"><div class="l">${esc(l)}</div><div class="v ${esc(c)}">${esc(v)}</div></div>`;
  const e = d.exc || {};
  const exTip = `Kedaluwarsa: ${esc(e.expired)} batch · Staging > 4 jam: ${esc(e.staging)} · Hold aktif: ${esc(e.hold)} · Rak ≥ ${FULL}%: ${esc(e.rack_full)}`;

  const flow = d.flow || [], mx = Math.max(1, ...flow.flatMap(f => [f.in, f.out]));
  const bars = flow.map((f, i) => `<div class="bc"><div class="bp"><i class="in" style="height:${f.in / mx * 100}%" title="Masuk ${fmt(f.in)} ctn"></i><i class="out" style="height:${f.out / mx * 100}%" title="Keluar ${fmt(f.out)} ctn"></i></div><span>${i === flow.length - 1 ? 'Hari ini' : esc(HARI[new Date(f.d + 'T00:00').getDay()])}</span></div>`).join('');

  const a = d.aging || {}, ag = [['0-30', a.b0], ['31-90', a.b1], ['91-180', a.b2], ['>180', a.b3], ['Exp', a.exp]];
  const am = Math.max(1, ...ag.map(x => x[1] || 0));
  const abars = ag.map(([l, n]) => `<div class="bc"><div class="bp"><i class="ag" style="height:${(n || 0) / am * 100}%" title="${fmt(n)} ctn"></i></div><span>${esc(l)}</span></div>`).join('');

  RK = (d.racks || []).filter(r => r.active);
  const blok = {};
  RK.forEach(r => { const b = blok[blokOf(r)] ||= { n: 0, used: 0, cap: 0 }; b.n++; b.used += r.used || 0; b.cap += r.capacity || 0; });
  const cnt = { full: 0, part: 0, empty: 0 };
  const tiles = Object.keys(blok).sort().map(k => {
    const b = blok[k], s = stOf(b.used, b.cap); cnt[s]++;
    return `<button class="rt g ${s}" data-a="blokOpen" data-v="${esc(k)}"><b>Rak ${esc(k)}</b><span>${esc(ST[s])}</span><small>${esc(fmt(b.used) + (b.cap > 0 ? '/' + fmt(b.cap) : '') + ' ctn · ' + b.n + ' lokasi')}</small></button>`;
  }).join('');

  $('#main').innerHTML = `<div class="kpis">${kpi('Total stok (ctn)', fmt(d.total))}${kpi('Tersedia untuk FEFO', fmt(d.available))}${kpi('Inbound / outbound proses', d.inbound_open + ' / ' + d.outbound_open)}${kpi('Exception terbuka', d.exceptions, d.exceptions > 0 ? 'bad' : '', exTip)}</div>
  <div class="two"><div class="card"><div class="ch"><h3>Inbound dan outbound 7 hari (ctn)</h3><span class="lg2">oranye masuk · biru keluar</span></div><div class="bars">${bars}</div></div>
  <div class="card"><div class="ch"><h3>Aging stok berdasarkan ED (ctn)</h3></div><div class="bars">${abars}</div><div class="cap">Kedaluwarsa: ${fmt(a.exp)} ctn · ≤ 90 hari: ${fmt((a.b0 || 0) + (a.b1 || 0))} ctn</div></div></div>
  <div class="card dbc"><div class="ch"><h3>Okupansi rak</h3><span class="lg2">${cnt.full} penuh · ${cnt.part} masih tersisa · ${cnt.empty} kosong</span></div><div class="rts grp">${tiles || '<span class="l">Belum ada rak.</span>'}</div><div class="leg"><i class="full"></i>Penuh<i class="part"></i>Terisi<i class="empty"></i>Kosong<span>· klik blok rak untuk detail</span></div></div>`;
}

export function registerDashboardActions(A) {
  A.blokOpen = (k) => {
    const rs = RK.filter(r => blokOf(r) === k);
    modal(`Rak ${k} — ${rs.length} lokasi`, `<div class="rts">${rs.map(rackTile).join('')}</div>`, null, '', '', '', 'wide');
  };
  A.rackOpen = async (code) => {
    const rows = await api.stockByRack(code);
    await api.whsEnsure(rows);
    const es = (x) => { const n = days(x); return n < 0 ? tag('exp', 'Kedaluwarsa') : n <= 90 ? tag('near', '≤ 90 hari') : tag('Aman', 'Aman'); };
    modal('Isi rak ' + code, T(['SKU', 'Whs', 'Nama', 'Batch', 'ED', 'Ctn', 'Status'], rows.map(r => `<tr><td>${esc(r.sku)}</td><td>${esc(api.whsOf(r.sku, r.batch))}</td><td>${esc(r.products?.name || '')}</td><td>${esc(r.batch)}</td><td>${esc(r.expiry)}</td><td class="num">${fmt(r.qty)}</td><td>${es(r.expiry)}</td></tr>`)), null, '', '', `<button class="btn o" data-a="blokOpen" data-v="${esc(code.charAt(0).toUpperCase())}">← Kembali</button>`, 'wide');
  };
}
