import { api } from '../api.js';
import { bno, askText, $, hd, T, bar, bt, ic, tag, sel, inp, v, fmt, modal, toast, rpcErr, findFreeNo, esc } from '../ui.js';

async function skuSelect(id) {
  const rows = await api.listActiveProducts();
  return sel(id, 'Produk*', rows.map(p => [p.sku, p.sku + ' — ' + p.name]));
}

export async function renderPackingList(go, W, back) {
  if (W === 'new') {
    const sup = await api.listActiveSuppliers();
    $('#main').innerHTML = hd('Tambah Packing List', back) +
      `<div class="card"><div class="row">${sel('plS', 'Pemasok*', sup.map(s => [s.name, s.name]))}<button class="btn o s" data-a="supNew">+ Pemasok baru</button>${inp('plT', 'Tanggal input FG', new Date().toISOString().slice(0,10), 'date')}<button class="btn" data-a="plCreate">Buat Packing List</button></div></div>`;
    return;
  }
  const rows = await api.listPackingLists();
  $('#main').innerHTML = hd('Packing List — Pemasok') + `<div class="card">${bar(bt('newW', '+ Tambah'))}${T(['Tanggal input FG', 'Kode', 'Pemasok', 'Status', 'Aksi'], rows.map(p => `<tr><td>${esc(p.doc_date)}</td><td>${esc(p.no)}</td><td>${esc(p.supplier)}</td><td>${tag(p.status, p.status === 'open' ? 'Menunggu' : 'Terpakai')}</td><td>${ic('plV', p.no, 'Lihat')}</td></tr>`))}</div>`;
}

// Format batch: YYYYMMDD.NNN  (tanggal ED tahun-bulan-hari + urutan batch). Kode produk sudah ada di kolom Produk.
const ymd = (d) => d.replaceAll('-', '');
async function autoBatch() {
  const ed = document.getElementById('plE')?.value, b = document.getElementById('plB'), k = document.getElementById('plK')?.value;
  if (!ed || !b) return;
  if (b.value.trim() && !b.dataset.auto) return; // jangan timpa ketikan manual
  b.value = ymd(ed) + '.' + await api.nextBatchSeq(k, ymd(ed)); b.dataset.auto = '1';
}

export function registerPackingListActions(A, go) {
  A.supNew = async () => {
    const n = await askText('Pemasok Baru', 'Nama pemasok*', 'Simpan', 'mis. FG-02 - Produksi B2'); if (!n) return;
    try { await api.addSupplier(n); toast('Pemasok ditambahkan.'); go('pl', 'new'); } catch (e) { rpcErr(e); }
  };
  A.plCreate = async () => {
    const s = v('plS'); if (!s) return toast('Pilih atau tambah pemasok dulu.');
    try {
      const no = await findFreeNo('PL', 'packing_lists', api);
      await api.createPackingList(no, s, v('plT'));
      toast('Packing List dibuat: ' + no);
      go('pl', null); await A.plV(no);
    } catch (e) { rpcErr(e); }
  };
  A.plV = async (no) => {
    const h = await api.getPackingList(no);
    const lines = await api.listPackingListLines(no);
    modal(no + ' — ' + h.supplier, (h.status === 'open' ? `<div class="row">${await skuSelect('plK')}<label>Batch*<input id="plB" type="text" placeholder="FGKGPA.001.20280310.001"></label>${inp('plPr', 'Tgl produksi', '', 'date')}${inp('plE', 'ED*', '', 'date')}${inp('plG', 'No GR (SAP)')}${inp('plQ', 'Jumlah (ctn)*', '100', 'number')}<button class="btn s" data-a="plAddLine" data-v="${esc(no)}">Tambah</button></div>` : '') +
      T(['SKU', 'Nama', 'Batch', 'No GR', 'Tgl produksi', 'ED', 'Jumlah'], lines.map(l => `<tr><td>${esc(l.sku)}</td><td>${esc(l.products?.name || '')}</td><td>${esc(l.batch)}</td><td>${esc(l.gr_no || '—')}</td><td>${esc(l.production_date || '—')}</td><td>${esc(l.expiry)}</td><td class="num">${fmt(l.qty)}</td></tr>`)),
      null, '', '', '', 'wide');
    // ED / produk diubah -> batch otomatis YYYYMMDD.NNN (bisa diedit manual)
    const B = document.getElementById('plB');
    B?.addEventListener('input', () => { delete B.dataset.auto; });
    document.getElementById('plE')?.addEventListener('change', autoBatch);
    document.getElementById('plK')?.addEventListener('change', () => { if (B) { B.dataset.auto = '1'; } autoBatch(); });
  };
  A.plAddLine = async (no) => {
    const e = v('plE'), b = v('plB').trim(), q = +v('plQ'), gr = v('plG').trim();
    if (!e) return toast('Isi ED.'); if (!b) return toast('Isi batch.');
    if (!/^\d{8}\.\d{3}$/.test(b)) return toast('Format batch: TahunBulanTanggal.NNN, contoh 20270930.001');
    if (b.slice(0, 8) !== ymd(e)) return toast('Tanggal di batch harus sama dengan ED (' + ymd(e) + ').'); if (!(q > 0)) return toast('Jumlah harus lebih dari 0.');
    try { await api.addPackingListLine(no, v('plK'), b, v('plPr'), e, q, gr); toast('Item ditambahkan.'); await A.plV(no); } catch (err) { rpcErr(err); }
  };
}
