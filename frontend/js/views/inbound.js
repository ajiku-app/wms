import { api } from '../api.js';
import { bno, askConfirm, $, hd, T, bar, bt, ic, tag, sel, v, fmt, toast, rpcErr, findFreeNo, esc } from '../ui.js';

export async function renderInbound(go, W, back) {
  if (W && W !== 'new') {
    const n = await api.getInboundDoc(W);
    const lines = await api.listInboundLines(W);
    const wh = (await api.supplierWhs())[n.supplier] || '—';
    const racks = await api.listActiveRacks();
    const ed = n.status === 'open';
    $('#main').innerHTML = hd('Inbound — ' + n.no, back) +
      `<div class="card"><div class="ch"><h3>Informasi</h3>${tag(n.status, n.status === 'open' ? 'Proses' : 'Selesai')}</div><div class="kv"><span>Warehouse</span><b>${esc(wh)}</b><span>Packing List</span><b>${esc(n.packing_list || '—')}</b><span>Pemasok</span><b>${esc(n.supplier || '—')}</b><span>Tanggal</span><b>${esc(n.doc_date)}</b></div></div>
      <div class="note">Barang diterima masuk ke <b>GR-STAGING</b>. Isi kolom Diterima dengan jumlah yang datang sekarang, lalu tempatkan ke rak lewat menu <b>Putaway</b>.</div><div class="card"><h3 style="margin-bottom:10px">Item</h3>${T(['SKU', 'Whs', 'Nama', 'Batch', 'No GR', 'ED', 'Jumlah PL', `Diterima${ed ? ' <button class="btn o s" data-a="inAll">Isi semua</button>' : ''}`, 'Rak'], lines.map((x, i) => `<tr><td>${esc(x.sku)}</td><td>${esc(wh)}</td><td>${esc(x.products?.name || '')}</td><td>${esc(bno(x.sku, x.batch))}</td><td>${esc(x.gr_no || '—')}</td><td>${esc(x.expiry)}</td><td class="num">${fmt(x.qty_pl)}</td><td>${ed ? `<input type="number" min="0" max="${Math.max(0, x.qty_pl - x.qty_received)}" data-max="${Math.max(0, x.qty_pl - x.qty_received)}" id="rt${i}" value="${Math.max(0, x.qty_pl - x.qty_received)}" style="width:90px"${x.qty_received >= x.qty_pl ? ' disabled' : ''}>` : fmt(x.qty_received)}</td><td>${esc(x.rack_code || 'GR-STAGING')}</td></tr>`))}
      ${ed ? `<p style="text-align:right"><button class="btn o" data-a="inAll">Terima semua sesuai Jumlah PL</button> ${bt('inSave', 'Simpan Penerimaan', n.no)} ${bt('inComplete', 'Selesaikan Inbound', n.no)}</p>` : ''}</div>
      <p style="text-align:right;margin:0"><button class="btn o s" data-a="lbl" data-v="${esc(n.no)}">Cetak Label</button></p>`;
    window._curLines = lines;
    return;
  }
  const rows = await api.listInboundDocs(), wmap = await api.supplierWhs();
  $('#main').innerHTML = hd('Inbound — Pemasok') + `<div class="card">${bar(bt('inM', '+ Inbound'))}${T(['Tanggal', 'Kode Inbound', 'Whs', 'Pemasok', 'Status', 'Aksi'], rows.map(x => `<tr><td>${esc(x.doc_date)}</td><td>${esc(x.no)}</td><td>${esc(wmap[x.supplier] || '—')}</td><td>${esc(x.supplier || '—')}</td><td>${tag(x.status, x.status === 'open' ? 'Proses' : 'Selesai')}</td><td>${ic('openW', x.no, x.status === 'open' ? 'Proses' : 'Lihat')} ${ic('lbl', x.no, 'Cetak Label')}</td></tr>`))}</div>`;
}

export function registerInboundActions(A, go) {
  A.inM = async () => {
    const [o, wl, wmap] = await Promise.all([api.listOpenPackingLists(), api.listWarehouses(), api.supplierWhs()]);
    if (!o.length) return toast('Belum ada Packing List berstatus Menunggu.');
    if (!wl.length) return toast('Kode warehouse (kolom Whs di tabel pemasok) belum diisi.');
    const { modal } = await import('../ui.js');
    modal('Tambah Inbound', sel('iw', 'Warehouse*', wl.map(x => [x.code, x.code])) + sel('ip', 'Packing List*', []), 'Buat Inbound', 'inNew');
    // daftar Packing List hanya milik pemasok di warehouse yang dipilih
    const fill = () => {
      const list = o.filter(p => wmap[p.supplier] === v('iw')), el = document.getElementById('ip');
      el.innerHTML = list.length ? list.map(p => `<option value="${esc(p.no)}">${esc(p.no)} — ${esc(p.supplier)}</option>`).join('') : '<option value="">Tidak ada Packing List Menunggu di warehouse ini</option>';
    };
    document.getElementById('iw').addEventListener('change', fill); fill();
  };
  A.inNew = async () => {
    const pl = v('ip'); if (!pl) return toast('Pilih Packing List.');
    try {
      const no = await findFreeNo('IN', 'inbound_docs', api);
      await api.createInboundFromPL(no, pl);
      A.mx(); toast('Inbound dibuat, status Proses.'); go('in', no);
    } catch (e) { rpcErr(e); }
  };
  // Batasi isian Diterima: tidak boleh melebihi sisa Jumlah PL (kurang boleh, lebih tidak)
  if (!window._inCap) {
    window._inCap = true;
    document.addEventListener('input', (e) => {
      const el = e.target;
      if (!el || !el.matches || !el.matches('input[data-max]')) return;
      const mx = +el.dataset.max;
      if (el.value !== '' && +el.value > mx) { el.value = mx; toast('Jumlah diterima tidak boleh melebihi Jumlah PL (maks ' + fmt(mx) + ').'); }
      if (+el.value < 0) el.value = 0;
    });
  }
  A.inSave = async (no) => {
    const lines = window._curLines; let ok = 0;
    // validasi semua baris dulu sebelum ada yang disimpan
    for (let i = 0; i < lines.length; i++) {
      const q = +v('rt' + i) || 0, sisa = Math.max(0, lines[i].qty_pl - lines[i].qty_received);
      if (q > sisa) return toast('Baris ' + lines[i].sku + ' (' + bno(lines[i].sku, lines[i].batch) + '): diterima ' + fmt(q) + ' melebihi sisa Jumlah PL ' + fmt(sisa) + '.');
    }
    for (let i = 0; i < lines.length; i++) {
      const q = +v('rt' + i) || 0, rack = 'GR-STAGING';
      if (q <= 0) continue;
      try { await api.receiveInboundLine(no, lines[i].sku, lines[i].batch, q, rack); ok++; } catch (e) { rpcErr(e); return; }
    }
    toast(ok + ' baris disimpan.'); go('in', no);
  };
  // Isi semua kolom Diterima dengan sisa Jumlah PL (Jumlah PL - sudah diterima). Belum tersimpan sampai klik Simpan Penerimaan.
  A.inAll = () => {
    const lines = window._curLines || []; let n = 0;
    lines.forEach((x, i) => {
      const el = document.getElementById('rt' + i), sisa = Math.max(0, x.qty_pl - x.qty_received);
      if (el) { el.value = sisa; if (sisa > 0) n++; }
    });
    toast(n ? n + ' baris diisi sesuai Jumlah PL. Klik Simpan Penerimaan untuk menyimpan.' : 'Semua baris sudah diterima penuh.');
  };
  A.inComplete = async (no) => {
    // peringatan: baris yang belum diterima penuh (berdasarkan data tersimpan, bukan isian di layar)
    const lines = window._curLines || [];
    const kurang = lines.filter(x => x.qty_received < x.qty_pl);
    const sisa = kurang.reduce((a, x) => a + (x.qty_pl - x.qty_received), 0);
    const pesan = kurang.length
      ? kurang.length + ' dari ' + lines.length + ' baris belum diterima penuh (kurang total ' + fmt(sisa) + '). Barang yang belum disimpan tidak masuk stok, dan setelah Selesai dokumen tidak bisa diubah lagi. Jika sudah mengisi kolom Diterima, klik Batal lalu Simpan Penerimaan dulu. Tetap selesaikan?'
      : 'Selesaikan inbound ini? Status akan berubah menjadi Selesai dan tidak bisa diubah lagi.';
    if (!await askConfirm(kurang.length ? 'Masih ada baris belum diterima' : 'Selesaikan Inbound', pesan, kurang.length ? 'Tetap Selesaikan' : 'Selesaikan')) return;
    try { await api.completeInbound(no); toast('Inbound selesai.'); go('in', no); } catch (e) { rpcErr(e); }
  };
}
