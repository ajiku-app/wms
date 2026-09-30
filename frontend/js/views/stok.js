import { api } from '../api.js';
import { $, hd, tag, fmt, v, toast, rpcErr, esc, csvCell } from '../ui.js';

// Filter, urutan, dan paging dijalankan di SERVER (RPC wms_stock_page) -> tetap cepat walau stok ribuan baris.
const S = { q: '', st: '', lim: 8, off: 0, sort: 'sku', dir: 'asc' };
let last = { total: 0, rows: [] }, tmr = null;
const ST = { Aman: ['Aman', 'Aman'], near: ['near', '≤ 90 hari'], exp: ['exp', 'Kedaluwarsa'], hold: ['hold', 'Hold'] };
const COLS = [['sku', 'SKU'], ['name', 'Nama'], ['batch', 'Batch'], ['rack', 'Rak'], ['ed', 'ED'], ['sisa', 'Sisa hari', 1], ['ctn', 'Ctn', 1], ['status', 'Status']];

const head = () => '<tr>' + COLS.map(([k, l, n]) => `<th data-a="stSort" data-v="${esc(k)}" ${n ? 'style="text-align:right"' : ''}>${esc(l)}${S.sort === k ? (S.dir === 'asc' ? ' ▲' : ' ▼') : ''}</th>`).join('') + '</tr>';
function paint() {
  const { total, rows } = last, pages = Math.max(1, Math.ceil(total / S.lim)), pg = Math.floor(S.off / S.lim) + 1;
  $('#stTb').innerHTML = `<div class="wrap"><table><thead>${head()}</thead><tbody>${rows.length ? rows.map(r => `<tr><td>${esc(r.sku)}</td><td>${esc(r.name)}</td><td>${esc(r.batch)}</td><td>${esc(r.rack)}</td><td>${esc(r.ed)}</td><td class="num">${esc(r.sisa)}</td><td class="num">${fmt(r.ctn)}</td><td>${tag(...ST[r.status])}</td></tr>`).join('') : `<tr><td colspan="8" class="empty">Data Tidak Ditemukan</td></tr>`}</tbody></table></div>
  <div class="pgr"><span>Server memuat ${rows.length} dari ${fmt(total)} baris (LIMIT ${esc(S.lim)} OFFSET ${esc(S.off)})</span><span class="pb"><button data-a="stPg" data-v="-1" ${pg <= 1 ? 'disabled' : ''}>‹</button><span>Hal ${pg}/${pages}</span><button data-a="stPg" data-v="1" ${pg >= pages ? 'disabled' : ''}>›</button></span></div>`;
}
async function load() { try { last = await api.stockPage(S); paint(); } catch (e) { rpcErr(e); } }

export async function renderStok() {
  $('#main').innerHTML = `<div class="card"><div class="flt"><label>Cari<input id="q" placeholder="SKU / nama / batch / rak" value="${esc(S.q)}"></label>
  <label>Status<select id="fs">${[['', 'Semua'], ['Aman', 'Aman'], ['near', '≤ 90 hari'], ['exp', 'Kedaluwarsa'], ['hold', 'Hold']].map(o => `<option value="${esc(o[0])}" ${S.st === o[0] ? 'selected' : ''}>${esc(o[1])}</option>`).join('')}</select></label>
  <label>Baris per halaman<select id="fl">${[8, 20, 50, 100].map(n => `<option ${S.lim === n ? 'selected' : ''}>${n}</option>`).join('')}</select></label>
  <button class="btn o sp" data-a="stCsv">Ekspor CSV</button></div><div id="stTb">Memuat…</div></div>`;
  $('#q').oninput = () => { clearTimeout(tmr); tmr = setTimeout(() => { S.q = v('q').trim(); S.off = 0; load(); }, 250); };
  $('#fs').onchange = () => { S.st = v('fs'); S.off = 0; load(); };
  $('#fl').onchange = () => { S.lim = +v('fl'); S.off = 0; load(); };
  await load();
}

export function registerStokActions(A) {
  A.stSort = (k) => { S.dir = S.sort === k && S.dir === 'asc' ? 'desc' : 'asc'; S.sort = k; S.off = 0; load(); };
  A.stPg = (d) => { S.off = Math.max(0, S.off + (+d) * S.lim); load(); };
  A.stCsv = async () => {
    try {
      const out = [['SKU', 'Nama', 'Batch', 'Rak', 'ED', 'Sisa hari', 'Ctn', 'Status']];
      for (let off = 0; ; off += 500) {
        const r = await api.stockPage({ ...S, lim: 500, off });
        r.rows.forEach(x => out.push([x.sku, x.name, x.batch, x.rack, x.ed, x.sisa, x.ctn, ST[x.status][1]]));
        if (r.rows.length < 500) break;
      }
      const csv = out.map(r => r.map(csvCell).join(',')).join('\n');
      const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(['\ufeff' + csv], { type: 'text/csv' }));
      a.download = 'informasi-stok.csv'; a.click(); URL.revokeObjectURL(a.href);
    } catch (e) { rpcErr(e); }
  };
}
