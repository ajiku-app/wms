import { api } from '../api.js';
import { bno, askConfirm, $, hd, T, bar, bt, ic, tag, sel, v, fmt, toast, rpcErr, findFreeNo, esc } from '../ui.js';

export async function renderInbound(go, W, back) {
  if (W && W !== 'new') {
    const n = await api.getInboundDoc(W);
    const lines = await api.listInboundLines(W);
    const racks = await api.listActiveRacks();
    const ed = n.status === 'open';
    $('#main').innerHTML = hd('Inbound — ' + n.no, back) +
      `<div class="card"><div class="ch"><h3>Informasi</h3>${tag(n.status, n.status === 'open' ? 'Proses' : 'Selesai')}</div><div class="kv"><span>Warehouse</span><b>Gudang FG</b><span>Packing List</span><b>${esc(n.packing_list || '—')}</b><span>Pemasok</span><b>${esc(n.supplier || '—')}</b><span>Tanggal</span><b>${esc(n.doc_date)}</b></div></div>
      <div class="note">Barang diterima masuk ke <b>GR-STAGING</b>. Isi kolom Diterima dengan jumlah yang datang sekarang, lalu tempatkan ke rak lewat menu <b>Putaway</b>.</div><div class="card"><h3 style="margin-bottom:10px">Item</h3>${T(['SKU', 'Nama', 'Batch', 'No GR', 'ED', 'Jumlah PL', 'Diterima', 'Rak'], lines.map((x, i) => `<tr><td>${esc(x.sku)}</td><td>${esc(x.products?.name || '')}</td><td>${esc(x.batch)}</td><td>${esc(x.gr_no || '—')}</td><td>${esc(x.expiry)}</td><td class="num">${fmt(x.qty_pl)}</td><td>${ed ? `<input type="number" min="0" id="rt${i}" value="${Math.max(0, x.qty_pl - x.qty_received)}" style="width:90px">` : fmt(x.qty_received)}</td><td>${esc(x.rack_code || 'GR-STAGING')}</td></tr>`))}
      ${ed ? `<p style="text-align:right">${bt('inSave', 'Simpan Penerimaan', n.no)} ${bt('inComplete', 'Selesaikan Inbound', n.no)}</p>` : ''}</div>
      <div class="ch"><h3 style="margin:0">Label</h3><button class="btn o s" data-a="lbl" data-v="${esc(n.no)}">Cetak Label</button></div>`;
    window._curLines = lines;
    return;
  }
  const rows = await api.listInboundDocs();
  $('#main').innerHTML = hd('Inbound — Pemasok') + `<div class="card">${bar(bt('inM', '+ Inbound'))}${T(['Tanggal', 'Kode Inbound', 'Warehouse', 'Pemasok', 'Status', 'Aksi'], rows.map(x => `<tr><td>${esc(x.doc_date)}</td><td>${esc(x.no)}</td><td>Gudang FG</td><td>${esc(x.supplier || '—')}</td><td>${tag(x.status, x.status === 'open' ? 'Proses' : 'Selesai')}</td><td>${ic('openW', x.no, x.status === 'open' ? 'Proses' : 'Lihat')} ${ic('lbl', x.no, 'Cetak Label')}</td></tr>`))}</div>`;
}

export function registerInboundActions(A, go) {
  A.inM = async () => {
    const o = await api.listOpenPackingLists();
    if (!o.length) return toast('Belum ada Packing List berstatus Menunggu.');
    const { modal } = await import('../ui.js');
    modal('Tambah Inbound', sel('iw', 'Warehouse*', [['Gudang FG', 'Gudang FG']]) + sel('ip', 'Packing List*', o.map(p => [p.no, `${p.no} — ${p.supplier}`])), 'Buat Inbound', 'inNew');
  };
  A.inNew = async () => {
    const pl = v('ip');
    try {
      const no = await findFreeNo('IN', 'inbound_docs', api);
      await api.createInboundFromPL(no, pl);
      A.mx(); toast('Inbound dibuat, status Proses.'); go('in', no);
    } catch (e) { rpcErr(e); }
  };
  A.inSave = async (no) => {
    const lines = window._curLines; let ok = 0;
    for (let i = 0; i < lines.length; i++) {
      const q = +v('rt' + i) || 0, rack = 'GR-STAGING';
      if (q <= 0) continue;
      try { await api.receiveInboundLine(no, lines[i].sku, lines[i].batch, q, rack); ok++; } catch (e) { rpcErr(e); return; }
    }
    toast(ok + ' baris disimpan.'); go('in', no);
  };
  A.inComplete = async (no) => {
    if (!await askConfirm('Selesaikan Inbound', 'Selesaikan inbound ini? Status akan berubah menjadi Selesai dan tidak bisa diubah lagi.', 'Selesaikan')) return;
    try { await api.completeInbound(no); toast('Inbound selesai.'); go('in', no); } catch (e) { rpcErr(e); }
  };
}
