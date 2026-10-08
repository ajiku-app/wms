import { api } from '../api.js';
import { ME } from '../auth.js';
import { bno, askConfirm, askText, $, hd, T, bar, bt, ic, tag, sel, inp, v, fmt, toast, rpcErr, findFreeNo, modal, esc } from '../ui.js';

// v2.0.20: format waktu muat (zona waktu perangkat) + durasi
const fdt = (t) => t ? new Date(t).toLocaleString('id-ID', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—';
const dur = (a, b) => { const m = Math.round((new Date(b) - new Date(a)) / 6e4); return m < 0 || isNaN(m) ? '—' : (m >= 60 ? Math.floor(m / 60) + ' jam ' : '') + (m % 60) + ' menit'; };
const dtl = (d) => new Date(d.getTime() - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 16); // untuk input datetime-local

let dob = []; // baris SKU+qty sementara sebelum outbound dibuat
let form = {}; // isian form (warehouse, customer, dst) agar tidak hilang saat halaman digambar ulang
// Item pesanan disimpan di database (outbound_items). localStorage hanya cadangan untuk outbound lama (< v2.0.12).
const legacyItems = (no) => { try { return JSON.parse(localStorage.getItem('wms_ob_items_' + no) || 'null') || []; } catch (e) { return []; } };
const loadItems = async (no) => { const r = await api.listOutboundItems(no); return r.length ? r : legacyItems(no); };
// Kekurangan alokasi per SKU = jumlah diminta - jumlah yang sudah masuk picking list
const shortOf = (items, picks) => items.map(it => ({ sku: it.sku, kurang: it.qty - picks.filter(p => p.sku === it.sku).reduce((a, p) => a + p.qty, 0) })).filter(x => x.kurang > 0);
// Alokasi FEFO hanya untuk kekurangan; hasilnya daftar SKU yang stoknya (di luar GR-STAGING) belum cukup
async function allocateShort(no, items) {
  const picks = await api.listOutboundPicks(no);
  const gagal = [];
  for (const x of shortOf(items, picks)) {
    const sisa = await api.fefoAllocate(no, x.sku, x.kurang);
    if (+sisa > 0) gagal.push(x.sku + ' kurang ' + fmt(+sisa) + ' ctn');
  }
  return gagal;
}
const keep = () => { form = { ow: v('ow'), ot: v('ot'), oc: v('oc'), otl: v('otl'), oa: v('oa') }; };

async function skuSelect(id) {
  const rows = await api.listActiveProducts();
  return sel(id, 'Produk*', rows.map(p => [p.sku, p.sku + ' — ' + p.name]));
}

export async function renderOutbound(go, W, back) {
  if (W === 'new') {
    const [cust, whl] = await Promise.all([api.listActiveCustomers(), api.listWarehouses()]);
    $('#main').innerHTML = hd('Tambah Outbound Manual', back) +
      `<div class="card"><h3 style="margin-bottom:10px">Informasi Warehouse</h3><div class="row">${sel('ow', 'Warehouse*', whl.map(x => [x.code, x.code]))}${inp('ot', 'Tanggal kirim', new Date().toISOString().slice(0,10), 'date')}</div></div>
      <div class="card"><h3 style="margin-bottom:10px">Informasi Penerima</h3><div class="row">${sel('oc', 'Customer*', cust.map(c => [c.name, c.name]))}<button class="btn o s" data-a="custNew">+ Customer baru</button>${inp('otl', 'No. Telepon')}</div><label>Alamat<textarea id="oa" rows="2"></textarea></label></div>
      <div class="card"><div class="ch"><h3>List Produk</h3><button class="btn s" data-a="obM">+ Tambah</button></div><div id="obLines">${dob.length ? T(['SKU', 'Jumlah (ctn)', ''], dob.map((x, i) => `<tr><td>${esc(x.sku)}</td><td class="num">${fmt(x.qty)}</td><td>${ic('obLn', i, 'Hapus', 'r')}</td></tr>`)) : '<div class="empty">Belum ada produk. Klik + Tambah.</div>'}</div><p style="text-align:right">${bt('obSave', 'Buat Outbound')}</p></div>`;
    Object.entries(form).forEach(([id, val]) => { const e = document.getElementById(id); if (e && val) e.value = val; });
    return;
  }
  if (W) {
    const o = await api.getOutboundDoc(W);
    const picks = await api.listOutboundPicks(W);
    await api.whsEnsure(picks);
    const kurangList = o.status === 'open' ? shortOf(await loadItems(o.no), picks) : [];
    $('#main').innerHTML = hd('Outbound — ' + o.no, back) +
      `<div class="card"><div class="ch"><h3>Informasi Pemesanan</h3>${tag(o.status, o.status === 'open' ? 'Proses' : 'Selesai')}</div><div class="kv"><span>Kode</span><b>${esc(o.no)}</b><span>Tanggal</span><b>${esc(o.doc_date)}</b><span>Warehouse</span><b>${esc(o.whs || '—')}</b></div>${o.status === 'done' && o.load_start ? `<h3 style="margin:14px 0 6px">Informasi Muat</h3><div class="kv"><span>Mulai muat</span><b>${esc(fdt(o.load_start))}</b><span>Selesai muat</span><b>${esc(fdt(o.load_end))}</b><span>Durasi</span><b>${esc(dur(o.load_start, o.load_end))}</b><span>No. kendaraan</span><b>${esc(o.vehicle_no || '—')}</b><span>Ekspedisi</span><b>${esc(o.expedition || '—')}</b><span>Petugas muat</span><b>${esc(o.loaders || '—')}</b></div>` : ''}<h3 style="margin:14px 0 6px">Informasi Pelanggan</h3><div class="kv"><span>Nama</span><b>${esc(o.customer_name)}</b><span>No. Telepon</span><b>${esc(o.customer_phone || '—')}</b><span>Alamat</span><b>${esc(o.customer_address || '—')}</b></div></div>
      <div class="card"><h3 style="margin-bottom:10px">Picking List (FEFO)</h3>${picks.length ? T(['Urutan', 'SKU', 'Whs', 'Rak', 'Batch', 'ED', 'Diambil / Target'], picks.map(p => `<tr><td>${esc(p.seq)}</td><td>${esc(p.sku)}</td><td>${esc(api.whsOf(p.sku, p.batch))}</td><td><b>${esc(p.rack_code)}</b></td><td>${esc(bno(p.sku, p.batch))}</td><td>${esc(p.expiry)}</td><td class="num">${fmt(p.picked)} / ${fmt(p.qty)}</td></tr>`)) : '<div class="empty">Belum dialokasikan.</div>'}${kurangList.length ? `<div class="note" style="margin-top:10px">Stok belum cukup: ${kurangList.map(x => esc(x.sku) + ' kurang ' + fmt(x.kurang) + ' ctn').join('; ')}. FEFO hanya mengambil dari rak penyimpanan — barang yang masih di <b>GR-STAGING</b> harus di-<b>Putaway</b> dulu, lalu klik tombol di bawah.</div>` : ''}
      <p style="text-align:right">${o.status === 'open' && (!picks.length || kurangList.length) ? `<button class="btn" data-a="obAlloc" data-v="${esc(o.no)}">${picks.length ? 'Alokasikan Kekurangan (FEFO)' : 'Buat Picking List (FEFO)'}</button> ` : ''}${o.status === 'open' && picks.length ? `<button class="btn o" data-a="obPickAll" data-v="${esc(o.no)}">Tandai Semua Terpick</button> <button class="btn" data-a="obDone" data-v="${esc(o.no)}">Selesai Kirim</button>` : ''}</p></div>`;
    return;
  }
  const rows = await api.listOutboundDocs();
  $('#main').innerHTML = hd('Outbound — Manual') + `<div class="card">${bar(bt('newW', '+ Outbound'))}${T(['Tanggal', 'Kode Outbound', 'Whs', 'Customer', 'Status', 'Aksi'], rows.map(x => `<tr><td>${esc(x.doc_date)}</td><td>${esc(x.no)}</td><td>${esc(x.whs || '—')}</td><td>${esc(x.customer_name)}</td><td>${tag(x.status, x.status === 'open' ? 'Proses' : 'Selesai')}</td><td>${ic('openW', x.no, 'Lihat')}</td></tr>`))}</div>`;
}

export function registerOutboundActions(A, go) {
  A.custNew = async () => {
    const n = await askText('Customer Baru', 'Nama customer*', 'Simpan', 'mis. PT Contoh Sejahtera'); if (!n) return;
    try { await api.addCustomer(n); toast('Customer ditambahkan.'); keep(); form.oc = n; go('out', 'new'); } catch (e) { rpcErr(e); }
  };
  A.obM = async () => modal('Tambah Produk', await skuSelect('obK') + inp('obQ', 'Jumlah (carton)*', '100', 'number'), 'Tambah', 'obAdd');
  A.obAdd = () => { const q = +v('obQ'); if (!(q > 0)) return toast('Jumlah harus lebih dari 0.'); dob.push({ sku: v('obK'), qty: q }); keep(); A.mx(); go('out', 'new'); };
  A.obLn = (i) => { dob.splice(+i, 1); keep(); go('out', 'new'); };
  A.obSave = async () => {
    if (!dob.length) return toast('Tambahkan minimal satu produk.');
    const whs = v('ow'); if (!whs) return toast('Pilih warehouse.');
    try {
      const no = await findFreeNo('DO', 'outbound_docs', api);
      await api.createOutboundDoc(no, v('oc'), v('otl'), v('oa'), whs);
      form = {};
      const items = dob.slice(); dob = [];
      await api.setOutboundItems(no, items);
      toast('Outbound dibuat. Membuat picking list…');
      try { const g = await allocateShort(no, items); if (g.length) toast('Stok belum cukup: ' + g.join('; ') + '. Putaway dulu dari GR-STAGING.'); } catch (e) { rpcErr(e); }
      go('out', no);
    } catch (e) { rpcErr(e); }
  };
  A.obAlloc = async (no) => {
    const items = await loadItems(no);
    if (!items.length) return toast('Item pesanan tidak ditemukan. Buat ulang outbound.');
    try {
      const g = await allocateShort(no, items);
      toast(g.length ? 'Sebagian belum teralokasi: ' + g.join('; ') + '. Putaway dulu dari GR-STAGING.' : 'Picking list dibuat.');
    } catch (e) { return rpcErr(e); }
    go('out', no);
  };
  A.obPickAll = async (no) => {
    const picks = await api.listOutboundPicks(no);
    for (const p of picks) {
      const sisa = p.qty - p.picked;
      if (sisa > 0) { try { await api.pick(no, p.sku, p.batch, p.rack_code, sisa); } catch (e) { return rpcErr(e); } }
    }
    toast('Semua baris ditandai terpick.'); go('out', no);
  };
  // v2.0.20: close outbound = isi data muat dulu (checker), baru dikirim ke server
  A.obDone = (no) => {
    const now = new Date(), start = new Date(now.getTime() - 30 * 6e4);
    modal('Selesaikan Pengiriman — Data Muat',
      '<p class="dlgp">Isi data proses muat sebelum DO ditutup. Semua kolom wajib.</p>'
      + inp('mtS', 'Waktu mulai muat*', dtl(start), 'datetime-local')
      + inp('mtE', 'Waktu selesai muat*', dtl(now), 'datetime-local')
      + inp('mtV', 'No. kendaraan*', '', 'text')
      + inp('mtX', 'Nama ekspedisi*', '', 'text')
      + inp('mtL', 'Petugas muat* (pisahkan dengan koma bila lebih dari satu)', '', 'text'),
      'Selesaikan', 'obDoneGo', no);
  };
  A.obDoneGo = async (no) => {
    const s = v('mtS'), e = v('mtE'), veh = v('mtV').trim(), exp = v('mtX').trim(), ldr = v('mtL').trim();
    if (!s || !e) return toast('Waktu mulai dan selesai muat wajib diisi.');
    if (new Date(e) <= new Date(s)) return toast('Waktu selesai muat harus setelah waktu mulai.');
    if (!veh) return toast('No. kendaraan wajib diisi.');
    if (!exp) return toast('Nama ekspedisi wajib diisi.');
    if (!ldr) return toast('Petugas muat wajib diisi.');
    const m = { start: new Date(s).toISOString(), end: new Date(e).toISOString(), vehicle: veh, expedition: exp, loaders: ldr };
    try { await api.completeOutbound(no, false, m); A.mx(); toast('Pengiriman selesai.'); go('out', no); }
    catch (err) {
      // v2.0.13: server menolak bila pesanan belum terpenuhi penuh. Admin/supervisor boleh menyelesaikan sebagian.
      if (/belum terpenuhi/.test((err && err.message) || '') && ME && ['admin', 'supervisor'].includes(ME.role)) {
        if (!await askConfirm('Pesanan belum terpenuhi penuh', String(err.message).replace(/^.*ERROR:\s*/, '') + ' Selesaikan sebagian (kirim yang sudah di-pick saja)?', 'Selesaikan Sebagian')) return;
        try { await api.completeOutbound(no, true, m); A.mx(); toast('Pengiriman selesai (sebagian).'); go('out', no); } catch (e2) { rpcErr(e2); }
      } else rpcErr(err);
    }
  };
}
