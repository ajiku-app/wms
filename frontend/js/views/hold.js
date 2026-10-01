import { api } from '../api.js';
import { $, hd, T, bar, tag, inp, v, fmt, modal, toast, rpcErr, askConfirm, esc } from '../ui.js';

const RS = { qc: 'Karantina QC', retur: 'Retur pelanggan', rusak: 'Rusak', kedaluwarsa: 'Kedaluwarsa' };
const es = (n) => n < 0 ? tag('exp', 'Kedaluwarsa') : n <= 90 ? tag('near', '≤ 90 hari') : tag('Aman', 'Aman');

export async function renderHold() {
  const rows = await api.holdList(); window._hold = rows;
  await api.whsEnsure(rows);
  $('#main').innerHTML = `<div class="note">Stok berstatus hold tidak akan dialokasikan oleh FEFO dan tidak dihitung sebagai tersedia.</div>
  <div class="card">${bar('')}${T(['SKU', 'Whs', 'Batch', 'Rak', 'Ctn', 'Status', 'Hold'], rows.map((r, i) => {
    const free = r.qty - r.held;
    const cur = r.holds.map(h => `${tag('hold', RS[h.reason] + ' · ' + fmt(h.qty) + ' ctn')} <button class="btn o s" data-a="holdRel" data-v="${esc(h.id)}">Lepas</button>`).join(' ');
    const sel = free > 0 ? `<select data-h="${i}"><option value="">Hold karena…</option>${Object.entries(RS).map(([k, l]) => `<option value="${esc(k)}">${esc(l)}</option>`).join('')}</select>` : '';
    return `<tr><td>${esc(r.sku)}</td><td>${esc(api.whsOf(r.sku, r.batch))}</td><td>${esc(r.batch)}</td><td>${esc(r.rack)}</td><td class="num">${fmt(r.qty)}</td><td>${es(r.sisa)}</td><td>${sel} ${cur}</td></tr>`;
  }))}</div>`;
  $('#main').onchange = (e) => { const s = e.target.closest('select[data-h]'); if (s && s.value) { const k = s.value; s.value = ''; window.holdAsk(+s.dataset.h, k); } };
}

export function registerHoldActions(A, go) {
  window.holdAsk = (i, reason) => {
    const r = window._hold[i], free = r.qty - r.held;
    modal(`Hold — ${RS[reason]}`, `<p class="l" style="margin:0 0 10px">${esc(r.sku)} · ${esc(r.batch)} · rak ${esc(r.rack)} · bebas ${fmt(free)} ctn</p>` + inp('hq', 'Jumlah di-hold (ctn)', free, 'number') + inp('hn', 'Catatan (opsional)'), 'Hold', 'holdGo', i + '|' + reason);
  };
  A.holdGo = async (s) => {
    const [i, reason] = s.split('|'), r = window._hold[+i], q = +v('hq');
    if (!(q > 0 && q <= r.qty - r.held)) return toast(`Jumlah harus 1 sampai ${r.qty - r.held}.`);
    try { await api.holdSet(r.sku, r.batch, r.rack, q, reason, v('hn')); A.mx(); toast('Stok di-hold.'); go('hold'); } catch (e) { rpcErr(e); }
  };
  A.holdRel = async (id) => {
    if (!await askConfirm('Lepas hold', 'Lepas hold ini? Stok akan kembali tersedia untuk FEFO (bila tidak kedaluwarsa).', 'Lepas')) return;
    try { await api.holdRelease(+id); toast('Hold dilepas.'); go('hold'); } catch (e) { rpcErr(e); }
  };
}
