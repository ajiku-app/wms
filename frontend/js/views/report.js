import { api } from '../api.js';
import { bno, $, hd, T, esc } from '../ui.js';

export async function renderReport() {
  const data = await api.listStockMovements(100);
  await api.whsEnsure(data);
  const nm = { GR: 'Inbound', GI: 'Outbound', MOVE: 'Mutasi', ADJ: 'Penyesuaian' };
  $('#main').innerHTML = hd('Report — Riwayat Transaksi') + `<div class="card">${T(['Waktu', 'Tipe', 'Ref', 'SKU', 'Whs', 'Batch', 'No GR', 'Dari', 'Ke', 'Jumlah'], data.map(l => `<tr><td>${new Date(l.moved_at).toLocaleString('id-ID')}</td><td>${esc(nm[l.type] || l.type)}</td><td>${esc(l.doc_no || '—')}</td><td>${esc(l.sku)}</td><td>${esc(api.whsOf(l.sku, l.batch))}</td><td>${esc(l.batch)}</td><td>${esc(l.gr_no || '—')}</td><td>${esc(l.from_rack || '—')}</td><td>${esc(l.to_rack || '—')}</td><td class="num">${esc(l.qty)}</td></tr>`))}</div>`;
}
