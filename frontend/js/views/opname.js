import { api } from '../api.js';
import { bno, askConfirm, $, hd, T, bar, bt, ic, tag, sel, inp, v, fmt, toast, rpcErr, findFreeNo, modal, esc } from '../ui.js';

async function skuSelect(id) {
  const rows = await api.listActiveProducts();
  return sel(id, 'Produk*', rows.map(p => [p.sku, p.sku + ' — ' + p.name]));
}

// Kotak status + tombol Freeze/Unfreeze (hanya admin/supervisor yang membuka halaman ini; server tetap menegakkan hak akses)
const fzBox = (fz) => fz?.active
  ? `<div class="note" style="border-left-color:var(--bad)"><b>Gudang sedang FREEZE.</b> Semua transaksi stok ditolak; hanya posting selisih opname yang diizinkan.${fz.note ? ' Catatan: ' + esc(fz.note) : ''} ${bt('fzTog', 'Unfreeze Gudang', '0')}</div>`
  : `<div class="note">Sebelum menghitung fisik, tekan <b>Freeze</b> agar tidak ada transaksi (terima, pick, pindah) selama opname. Setelah posting selisih, tekan <b>Unfreeze</b>. ${bt('fzTog', 'Freeze Gudang', '1')}</div>`;

export async function renderOpname(go, W, back) {
  if (W && W !== 'new') {
    const o = await api.getOpnameDoc(W);
    const lines = await api.listOpnameLines(W);
    await api.whsEnsure(lines.map(x => ({ sku: o.sku, batch: x.batch })));
    const ed = o.status === 'open';
    const fz = await api.freezeStatus().catch(() => null);
    $('#main').innerHTML = hd('Stok Opname — ' + o.no, back) + (ed ? fzBox(fz) : '') +
      `<div class="card"><div class="ch"><h3>${esc(o.sku)}</h3>${tag(o.status, o.status === 'open' ? 'Proses' : 'Selesai')}</div>${T(['Whs', 'Batch', 'Rak', 'Sistem', 'Fisik'], lines.map((x, i) => `<tr><td>${esc(api.whsOf(o.sku, x.batch))}</td><td>${esc(bno(o.sku, x.batch))}</td><td>${esc(x.rack_code)}</td><td class="num">${fmt(x.qty_system)}</td><td>${ed ? `<input type="number" min="0" id="of${i}" value="${esc(x.qty_physical ?? x.qty_system)}" style="width:110px">` : fmt(x.qty_physical)}</td></tr>`))}${ed ? `<p style="text-align:right">${bt('opSet', 'Simpan Hitungan', o.no)} ${bt('opPost', 'Posting Selisih', o.no)}</p>` : ''}</div>`;
    window._opLines = lines;
    return;
  }
  const rows = await api.listOpnameDocs();
  const fz = await api.freezeStatus().catch(() => null);
  $('#main').innerHTML = hd('Stok Opname') + fzBox(fz) + `<div class="card">${bar(bt('opM', '+ Stok Opname'))}${T(['Tanggal', 'Kode', 'SKU', 'Status', 'Aksi'], rows.map(x => `<tr><td>${esc(x.doc_date)}</td><td>${esc(x.no)}</td><td>${esc(x.sku)}</td><td>${tag(x.status, x.status === 'open' ? 'Proses' : 'Selesai')}</td><td>${ic('openW', x.no, x.status === 'open' ? 'Hitung' : 'Lihat')}</td></tr>`))}</div>`;
}

export function registerOpnameActions(A, go) {
  A.fzTog = async (on) => {
    const aktif = on === '1';
    if (!await askConfirm(aktif ? 'Freeze Gudang' : 'Unfreeze Gudang', aktif ? 'Semua transaksi stok (terima, pick, pindah, putaway, penyesuaian) akan DITOLAK sampai Unfreeze. Pastikan operator scan sudah sinkron (antrian kirim kosong). Lanjutkan?' : 'Buka kembali transaksi stok? Pastikan posting selisih opname sudah selesai.', aktif ? 'Freeze' : 'Unfreeze')) return;
    try { await api.setFreeze(aktif, aktif ? 'Stok opname' : null); toast(aktif ? 'Gudang di-FREEZE.' : 'Gudang dibuka kembali.'); document.dispatchEvent(new Event('wms-freeze')); const m = /^#\/opn\/([A-Za-z0-9._-]+)$/.exec(location.hash); go('opn', m && m[1] !== 'new' ? m[1] : null); } catch (e) { rpcErr(e); }
  };
  A.opM = async () => modal('Tambah Stok Opname', await skuSelect('oS') + inp('cn', 'Petugas hitung'), 'Buat Stok Opname', 'opNew');
  A.opNew = async () => {
    try {
      const no = await findFreeNo('SO', 'opname_docs', api);
      await api.createOpname(no, v('oS'), v('cn'));
      A.mx(); go('opn', no);
    } catch (e) { rpcErr(e); }
  };
  A.opSet = async (no) => {
    const lines = window._opLines;
    for (let i = 0; i < lines.length; i++) {
      const t = v('of' + i); if (t === '') continue;
      try { await api.setOpnameLine(no, lines[i].batch, lines[i].rack_code, +t); } catch (e) { return rpcErr(e); }
    }
    toast('Hitungan tersimpan.'); go('opn', no);
  };
  A.opPost = async (no) => {
    if (!await askConfirm('Posting Stok Opname', 'Posting selisih opname ini? Stok sistem akan disesuaikan dengan hasil hitung fisik.', 'Posting')) return;
    try { const r = await api.postOpname(no); toast('Selisih diposting: ' + (r?.selisih ?? 0) + ' baris.'); go('opn', no); } catch (e) { rpcErr(e); }
  };
}
