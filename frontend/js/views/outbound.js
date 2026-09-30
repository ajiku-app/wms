import { api } from '../api.js';
import { bno, askConfirm, askText, $, hd, T, bar, bt, ic, tag, sel, inp, v, fmt, toast, rpcErr, findFreeNo, modal, esc } from '../ui.js';

let dob = []; // baris SKU+qty sementara sebelum outbound dibuat

async function skuSelect(id) {
  const rows = await api.listActiveProducts();
  return sel(id, 'Produk*', rows.map(p => [p.sku, p.sku + ' — ' + p.name]));
}

export async function renderOutbound(go, W, back) {
  if (W === 'new') {
    const cust = await api.listActiveCustomers();
    $('#main').innerHTML = hd('Tambah Outbound Manual', back) +
      `<div class="card"><h3 style="margin-bottom:10px">Informasi Warehouse</h3><div class="row">${sel('ow', 'Warehouse*', [['Gudang FG', 'Gudang FG']])}${inp('ot', 'Tanggal kirim', new Date().toISOString().slice(0,10), 'date')}</div></div>
      <div class="card"><h3 style="margin-bottom:10px">Informasi Penerima</h3><div class="row">${sel('oc', 'Customer*', cust.map(c => [c.name, c.name]))}<button class="btn o s" data-a="custNew">+ Customer baru</button>${inp('otl', 'No. Telepon')}</div><label>Alamat<textarea id="oa" rows="2"></textarea></label></div>
      <div class="card"><div class="ch"><h3>List Produk</h3><button class="btn s" data-a="obM">+ Tambah</button></div><div id="obLines">${dob.length ? T(['SKU', 'Jumlah (ctn)', ''], dob.map((x, i) => `<tr><td>${esc(x.sku)}</td><td class="num">${fmt(x.qty)}</td><td>${ic('obLn', i, 'Hapus', 'r')}</td></tr>`)) : '<div class="empty">Belum ada produk. Klik + Tambah.</div>'}</div><p style="text-align:right">${bt('obSave', 'Buat Outbound')}</p></div>`;
    return;
  }
  if (W) {
    const o = await api.getOutboundDoc(W);
    const picks = await api.listOutboundPicks(W);
    $('#main').innerHTML = hd('Outbound — ' + o.no, back) +
      `<div class="card"><div class="ch"><h3>Informasi Pemesanan</h3>${tag(o.status, o.status === 'open' ? 'Proses' : 'Selesai')}</div><div class="kv"><span>Kode</span><b>${esc(o.no)}</b><span>Tanggal</span><b>${esc(o.doc_date)}</b><span>Warehouse</span><b>Gudang FG</b></div><h3 style="margin:14px 0 6px">Informasi Pelanggan</h3><div class="kv"><span>Nama</span><b>${esc(o.customer_name)}</b><span>No. Telepon</span><b>${esc(o.customer_phone || '—')}</b><span>Alamat</span><b>${esc(o.customer_address || '—')}</b></div></div>
      <div class="card"><h3 style="margin-bottom:10px">Picking List (FEFO)</h3>${picks.length ? T(['Urutan', 'SKU', 'Rak', 'Batch', 'ED', 'Diambil / Target'], picks.map(p => `<tr><td>${esc(p.seq)}</td><td>${esc(p.sku)}</td><td><b>${esc(p.rack_code)}</b></td><td>${esc(p.batch)}</td><td>${esc(p.expiry)}</td><td class="num">${fmt(p.picked)} / ${fmt(p.qty)}</td></tr>`)) : '<div class="empty">Belum dialokasikan.</div>'}
      <p style="text-align:right">${o.status === 'open' && !picks.length ? `<button class="btn" data-a="obAlloc" data-v="${esc(o.no)}">Buat Picking List (FEFO)</button>` : ''}${o.status === 'open' && picks.length ? `<button class="btn o" data-a="obPickAll" data-v="${esc(o.no)}">Tandai Semua Terpick</button> <button class="btn" data-a="obDone" data-v="${esc(o.no)}">Selesai Kirim</button>` : ''}</p></div>`;
    return;
  }
  const rows = await api.listOutboundDocs();
  $('#main').innerHTML = hd('Outbound — Manual') + `<div class="card">${bar(bt('newW', '+ Outbound'))}${T(['Tanggal', 'Kode Outbound', 'Customer', 'Status', 'Aksi'], rows.map(x => `<tr><td>${esc(x.doc_date)}</td><td>${esc(x.no)}</td><td>${esc(x.customer_name)}</td><td>${tag(x.status, x.status === 'open' ? 'Proses' : 'Selesai')}</td><td>${ic('openW', x.no, 'Lihat')}</td></tr>`))}</div>`;
}

export function registerOutboundActions(A, go) {
  A.custNew = async () => {
    const n = await askText('Customer Baru', 'Nama customer*', 'Simpan', 'mis. PT Contoh Sejahtera'); if (!n) return;
    try { await api.addCustomer(n); toast('Customer ditambahkan.'); go('out', 'new'); } catch (e) { rpcErr(e); }
  };
  A.obM = async () => modal('Tambah Produk', await skuSelect('obK') + inp('obQ', 'Jumlah (carton)*', '100', 'number'), 'Tambah', 'obAdd');
  A.obAdd = () => { const q = +v('obQ'); if (!(q > 0)) return toast('Jumlah harus lebih dari 0.'); dob.push({ sku: v('obK'), qty: q }); A.mx(); go('out', 'new'); };
  A.obLn = (i) => { dob.splice(+i, 1); go('out', 'new'); };
  A.obSave = async () => {
    if (!dob.length) return toast('Tambahkan minimal satu produk.');
    try {
      const no = await findFreeNo('DO', 'outbound_docs', api);
      await api.createOutboundDoc(no, v('oc'), v('otl'), v('oa'));
      const items = dob.slice(); dob = [];
      toast('Outbound dibuat. Membuat picking list…');
      window._pendingItems = items;
      for (const it of items) { try { await api.fefoAllocate(no, it.sku, it.qty); } catch (e) { rpcErr(e); } }
      go('out', no);
    } catch (e) { rpcErr(e); }
  };
  A.obAlloc = async (no) => {
    const items = window._pendingItems;
    if (!items || !items.length) return toast('Tidak ada item tersimpan untuk dialokasikan. Buat ulang outbound.');
    for (const it of items) { try { await api.fefoAllocate(no, it.sku, it.qty); } catch (e) { return rpcErr(e); } }
    toast('Picking list dibuat.'); go('out', no);
  };
  A.obPickAll = async (no) => {
    const picks = await api.listOutboundPicks(no);
    for (const p of picks) {
      const sisa = p.qty - p.picked;
      if (sisa > 0) { try { await api.pick(no, p.sku, p.batch, p.rack_code, sisa); } catch (e) { return rpcErr(e); } }
    }
    toast('Semua baris ditandai terpick.'); go('out', no);
  };
  A.obDone = async (no) => {
    if (!await askConfirm('Selesaikan Pengiriman', 'Selesaikan pengiriman ini? Stok akan dikurangi sesuai barang yang sudah di-pick.', 'Selesaikan')) return;
    try { await api.completeOutbound(no); toast('Pengiriman selesai.'); go('out', no); } catch (e) { rpcErr(e); }
  };
}
