import { api } from '../api.js';
import { bno, $, hd, fmt, v, toast, rpcErr, esc } from '../ui.js';

const jam = (h) => h < 1 ? '< 1 jam' : h < 48 ? Math.round(h) + ' jam' : Math.floor(h / 24) + ' hari';
// Putaway per PALLET: butuh 1 slot pallet di bin tujuan. Saran: rak yang sudah berisi SKU sama lebih dulu, lalu slot kosong terbanyak
// (kapasitas 0 = tidak dibatasi, paling akhir). Maks. 5 rak.
function suggest(r, racks) {
  const free = (k) => k.capacity > 0 ? k.capacity - k.used : -1;
  return racks.filter(k => k.active && k.code !== 'GR-STAGING' && (k.capacity === 0 || free(k) >= 1))
    .sort((a, b) => (b.skus.includes(r.sku) - a.skus.includes(r.sku)) || (free(b) - free(a)) || a.code.localeCompare(b.code)).slice(0, 5);
}
const spc = (k) => k && k.capacity > 0 ? fmt(k.capacity - k.used) + ' slot pallet' : 'tidak dibatasi';

export async function renderPutaway() {
  const [rows, racks] = await Promise.all([api.stagingPending(), api.rackLoad()]);
  await api.whsEnsure(rows);
  window._put = { rows, racks };
  $('#main').innerHTML = `<div class="note">Putaway dilakukan per <b>pallet</b> (satu batch = satu pallet). Saran rak memprioritaskan rak yang sudah berisi SKU sama, lalu rak dengan slot pallet kosong terbanyak.</div>
  <div class="card"><div class="ch"><h3>Menunggu putaway</h3><span class="lg2">${rows.length} baris</span></div>
  <div class="wrap"><table><thead><tr><th>SKU</th><th>Whs</th><th>Batch</th><th style="text-align:right">Ctn</th><th>Di staging</th><th>Rak tujuan</th><th>Sisa slot</th><th></th></tr></thead><tbody>${rows.length ? rows.map((r, i) => {
    const s = suggest(r, racks), mv = r.qty - r.held, ok = mv > 0 && !r.held; // pallet yang sebagian di-hold tidak bisa dipindah
    const opt = s.length ? s.map((k, j) => `<option value="${esc(k.code)}">${esc(k.code)}${j === 0 ? ' (disarankan)' : ''}</option>`).join('') : '<option value="">Tidak ada rak yang muat</option>';
    return `<tr><td>${esc(r.sku)}</td><td>${esc(api.whsOf(r.sku, r.batch))}</td><td>${esc(bno(r.sku, r.batch))}</td><td class="num">${fmt(mv)}${r.held ? ` <small class="l">(+${fmt(r.held)} hold)</small>` : ''}</td><td>${jam(r.hours)}</td>
    <td>${ok ? `<select data-pi="${i}" id="pr${i}">${opt}</select>` : '<span class="l">Di-hold</span>'}</td><td class="pfx" id="pf${i}">${s[0] ? spc(s[0]) : '—'}</td>
    <td>${ok && s.length ? `<button class="btn go" data-a="putGo" data-v="${i}">Konfirmasi</button>` : ''}</td></tr>`;
  }).join('') : '<tr><td colspan="8" class="empty">Tidak ada barang menunggu putaway</td></tr>'}</tbody></table></div></div>`;
  $('#main').querySelectorAll('select[data-pi]').forEach(s => { s.onchange = () => { $('#pf' + s.dataset.pi).textContent = spc(racks.find(k => k.code === s.value)); }; });
}

export function registerPutawayActions(A, go) {
  A.putGo = async (i) => {
    const r = window._put.rows[+i], rack = v('pr' + i);
    if (!rack) return toast('Pilih rak tujuan.');
    try { await api.putaway(r.sku, r.batch, rack, r.qty - r.held); toast(`Putaway ${r.sku} → ${rack} tersimpan.`); go('put'); } catch (e) { rpcErr(e); }
  };
}
