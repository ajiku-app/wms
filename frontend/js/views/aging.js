import { api } from '../api.js';
import { $, T, fmt, v, rpcErr, esc, csvCell } from '../ui.js';

let D = 30, data = null, tmr = null;
const batchTbl = () => `<h3 style="margin:18px 0 6px" id="agh">Batch dengan ED ≤ ${D} hari (${data.batches.length})</h3>${T(['SKU', 'Batch', 'Rak', 'Sisa hari', 'Ctn'].map((h, i) => i > 2 ? `<span style="display:block;text-align:right">${esc(h)}</span>` : h),
  data.batches.map(b => `<tr><td>${esc(b.sku)}</td><td>${esc(b.batch)}</td><td>${esc(b.rack)}</td><td class="num">${esc(b.sisa)}</td><td class="num">${fmt(b.qty)}</td></tr>`))}`;

export async function renderAging() {
  data = await api.aging(D);
  $('#main').innerHTML = `<div class="card"><div class="flt"><label style="flex:0 1 320px">Tampilkan ED dalam<div class="sv"><input id="ag" type="range" min="0" max="365" step="5" value="${D}"><b id="agv">${D} hari</b></div></label><button class="btn o sp" data-a="agCsv">Ekspor CSV</button></div>
  <h3 style="margin:0 0 6px">Aging per SKU (ctn)</h3>${T(['SKU', 'Nama', '0-30', '31-90', '91-180', '>180', 'Expired'].map((h, i) => i > 1 ? `<span style="display:block;text-align:right">${esc(h)}</span>` : h),
    data.skus.map(s => `<tr><td>${esc(s.sku)}</td><td>${esc(s.name)}</td><td class="num">${fmt(s.b0)}</td><td class="num">${fmt(s.b1)}</td><td class="num">${fmt(s.b2)}</td><td class="num">${fmt(s.b3)}</td><td class="num">${fmt(s.exp)}</td></tr>`))}<div id="agb">${batchTbl()}</div></div>`;
  $('#ag').oninput = () => {
    D = +v('ag'); $('#agv').textContent = D + ' hari';
    clearTimeout(tmr); tmr = setTimeout(async () => { try { data = await api.aging(D); $('#agb').innerHTML = batchTbl(); } catch (e) { rpcErr(e); } }, 200);
  };
}

export function registerAgingActions(A) {
  A.agCsv = () => {
    const q = (r) => r.map(csvCell).join(',');
    const out = [q(['Aging per SKU (ctn)']), q(['SKU', 'Nama', '0-30', '31-90', '91-180', '>180', 'Expired']), ...data.skus.map(s => q([s.sku, s.name, s.b0, s.b1, s.b2, s.b3, s.exp])),
      '', q([`Batch dengan ED <= ${D} hari`]), q(['SKU', 'Batch', 'Rak', 'Sisa hari', 'Ctn']), ...data.batches.map(b => q([b.sku, b.batch, b.rack, b.sisa, b.qty]))];
    const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(['\ufeff' + out.join('\n')], { type: 'text/csv' }));
    a.download = 'laporan-aging-ed.csv'; a.click(); URL.revokeObjectURL(a.href);
  };
}
