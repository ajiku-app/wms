import { api } from '../api.js';
import { bno, $, hd, T, sel, inp, v, fmt, bt, toast, rpcErr, esc } from '../ui.js';

export async function renderAdjust() {
  const rows = await api.listStockForAdjust();
  window._ar = rows;
  const log = await api.listAdjustLog();
  $('#main').innerHTML = hd('Penyesuaian Stok') +
    `<div class="card"><h3 style="margin-bottom:10px">Penyesuaian manual</h3><div class="row">${sel('aF', 'Stok (SKU · batch · rak)', rows.map((r, i) => [i, `${r.sku} · ${r.batch} · ${r.rack_code} (${fmt(r.qty)} ctn)`]))}${inp('aQ', 'Jumlah baru (carton)', '', 'number')}${inp('aR', 'Alasan*')}${bt('adjGo', 'Simpan')}</div></div>
    <div class="card"><h3 style="margin-bottom:10px">Riwayat penyesuaian</h3>${T(['Waktu', 'Ref', 'SKU', 'Batch', 'Rak', 'Selisih'], log.map(l => `<tr><td>${new Date(l.moved_at).toLocaleString('id-ID')}</td><td>${esc(l.doc_no)}</td><td>${esc(l.sku)}</td><td>${esc(l.batch)}</td><td>${esc(l.to_rack)}</td><td class="num">${l.qty > 0 ? '+' : ''}${esc(l.qty)}</td></tr>`))}</div>`;
}

export function registerAdjustActions(A, go) {
  A.adjGo = async () => {
    const r = window._ar[+v('aF')], t = v('aQ'), a = v('aR').trim();
    if (!r) return toast('Tidak ada stok.');
    if (t === '' || +t < 0) return toast('Isi jumlah baru (0 atau lebih).');
    if (!a) return toast('Alasan wajib diisi.');
    try { await api.adjustStock(r.sku, r.batch, r.rack_code, +t, a); toast('Penyesuaian tersimpan.'); go('adj'); } catch (e) { rpcErr(e); }
  };
}
