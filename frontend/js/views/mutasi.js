import { api } from '../api.js';
import { bno, $, hd, T, sel, inp, v, fmt, bt, toast, rpcErr, esc } from '../ui.js';

export async function renderMutasi() {
  const racks = await api.listActiveRacks();
  const stock = await api.listStockForMove();
  window._mr = stock;
  const mv = await api.listMoveHistory();
  await api.whsEnsure([...stock, ...mv]);
  $('#main').innerHTML = hd('Mutasi — Pindah Rak') +
    `<div class="card"><h3 style="margin-bottom:10px">Pindah pallet antar rak</h3><div class="row">${sel('mF', 'Dari (rak · SKU · batch)', stock.map((r, i) => [i, `${api.whsOf(r.sku, r.batch)} · ${r.rack_code} · ${r.sku} · ${bno(r.sku, r.batch)} (${fmt(r.qty)} ctn)`]))}<label>Jumlah<input value="1 pallet (seluruh isi)" disabled></label>${sel('mT', 'Ke rak', racks.map(r => [r.code, r.code]))}${bt('mutGo', 'Pindahkan')}</div></div>
    <div class="card"><h3 style="margin-bottom:10px">Riwayat mutasi</h3>${T(['Waktu', 'SKU', 'Whs', 'Batch', 'Dari', 'Ke', 'Jumlah'], mv.map(l => `<tr><td>${new Date(l.moved_at).toLocaleString('id-ID')}</td><td>${esc(l.sku)}</td><td>${esc(api.whsOf(l.sku, l.batch))}</td><td>${esc(bno(l.sku, l.batch))}</td><td>${esc(l.from_rack)}</td><td>${esc(l.to_rack)}</td><td class="num">${fmt(l.qty)}</td></tr>`))}</div>`;
}

export function registerMutasiActions(A, go) {
  A.mutGo = async () => {
    const r = window._mr[+v('mF')], to = v('mT');
    if (!r) return toast('Tidak ada stok untuk dipindah.'); // selalu satu pallet utuh
    try { await api.moveStock(r.sku, r.batch, r.rack_code, to, r.qty); toast('Mutasi tersimpan.'); go('mut'); } catch (e) { rpcErr(e); }
  };
}
