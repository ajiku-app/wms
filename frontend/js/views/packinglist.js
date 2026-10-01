import { api } from '../api.js';
import { bno, askText, askConfirm, $, hd, T, bar, bt, ic, tag, sel, inp, v, fmt, modal, toast, rpcErr, findFreeNo, esc } from '../ui.js';

async function skuSelect(id) {
  const rows = await api.listActiveProducts();
  return sel(id, 'Produk*', rows.map(p => [p.sku, p.sku + ' — ' + p.name]));
}

export async function renderPackingList(go, W, back) {
  if (W === 'new') {
    const sup = await api.listActiveSuppliers();
    $('#main').innerHTML = hd('Tambah Packing List', back) +
      `<div class="card"><div class="row">${sel('plS', 'Pemasok*', sup.map(s => [s.name, s.Whs ? s.Whs + ' — ' + s.name : s.name]))}<button class="btn o s" data-a="supNew">+ Pemasok baru</button>${inp('plT', 'Tanggal input FG', new Date().toISOString().slice(0,10), 'date')}<button class="btn" data-a="plCreate">Buat Packing List</button></div></div>`;
    return;
  }
  const rows = await api.listPackingLists(), wmap = await api.supplierWhs(), gmap = await api.packingListGr();
  const acts = (p) => p.status === 'open'
    ? ic('plV', p.no, 'Lihat') + ' ' + ic('plEdit', p.no, 'Edit') + ' ' + ic('plDel', p.no, 'Hapus', 'r')
    : ic('plV', p.no, 'Lihat') + ' <button class="btn o s" disabled title="Packing List sudah dipakai Inbound">Edit</button> <button class="btn o s" disabled title="Packing List sudah dipakai Inbound">Hapus</button>';
  $('#main').innerHTML = hd('Packing List — Pemasok') + `<div class="card">${bar(bt('newW', '+ Tambah'))}${T(['Tanggal input FG', 'Kode', 'Whs', 'Pemasok', 'GR', 'Status', 'Aksi'], rows.map(p => `<tr><td>${esc(p.doc_date)}</td><td>${esc(p.no)}</td><td>${esc(wmap[p.supplier] || '—')}</td><td>${esc(p.supplier)}</td><td>${esc((gmap[p.no] || []).join(', ') || '—')}</td><td>${tag(p.status, p.status === 'open' ? 'Menunggu' : 'Terpakai')}</td><td>${acts(p)}</td></tr>`))}</div>`;
}

// Batch otomatis per PALLET: <prefix SKU>.<YYYYMMDD ED>.<NNN>, mis. FGKGTN.001.20280310.003
// Di database disimpan pendek (20280310.003); prefix SKU ditambahkan saat tampil (lihat bno).
// Jumlah produksi dipecah per isi pallet: 500 ctn @56 -> 8 pallet x 56 + 1 pallet x 52 = batch .001 s/d .009
const ymd = (d) => d.replaceAll('-', '');
const perKey = (sku) => 'wms_ctn_pallet_' + sku; // sama dengan yang dipakai label.js
const perDef = (sku) => { try { return localStorage.getItem(perKey(sku)) || ''; } catch (e) { return ''; } };
const pad3 = (n) => String(n).padStart(3, '0');
function splitQty(q, per) {
  if (!per || q <= per) return [q];
  const n = Math.ceil(q / per), a = [];
  for (let i = 0; i < n; i++) a.push(i < n - 1 ? per : q - per * (n - 1));
  return a;
}
let PLS = null; // nomor urut batch berikutnya untuk SKU + ED yang sedang diisi: {k, y, start}

function plPrev() {
  const el = document.getElementById('plPv'); if (!el) return;
  const k = v('plK'), ed = v('plE'), q = +v('plQ'), per = parseInt(v('plPer'), 10);
  if (!ed) { el.textContent = 'Isi ED untuk melihat nomor batch.'; return; }
  if (!(q > 0) || !Number.isInteger(q)) { el.textContent = 'Isi jumlah (ctn) berupa bilangan bulat.'; return; }
  if (!(per >= 0)) { el.textContent = 'Isi "Isi per pallet" (0 = tidak dipecah, 1 batch).'; return; }
  const parts = splitQty(q, per), n = parts.length, last = parts[n - 1], y = ymd(ed);
  const desc = n === 1 ? '1 pallet × ' + fmt(q) + ' ctn' : (last === parts[0] ? n + ' pallet × ' + fmt(parts[0]) + ' ctn' : (n - 1) + ' pallet × ' + fmt(parts[0]) + ' ctn + 1 pallet × ' + fmt(last) + ' ctn');
  if (!PLS || PLS.k !== k || PLS.y !== y) { el.textContent = '→ ' + desc + ' — menghitung nomor batch…'; return; }
  const bn = (i) => bno(k, y + '.' + pad3(i));
  el.textContent = '→ ' + desc + ' · Batch ' + bn(PLS.start) + (n > 1 ? ' s/d ' + bn(PLS.start + n - 1) : '');
}
async function plSeq() {
  const ed = v('plE'), k = v('plK'); PLS = null; plPrev();
  if (!ed || !k) return;
  const y = ymd(ed), start = parseInt(await api.nextBatchSeq(k, y), 10) || 1;
  if (v('plE') !== ed || v('plK') !== k) return; // input sudah berubah lagi
  PLS = { k, y, start }; plPrev();
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
    const wh = (await api.supplierWhs())[h.supplier] || '—';
    const lines = (await api.listPackingListLines(no)).slice().sort((a, b) => String(a.sku).localeCompare(String(b.sku)) || String(a.batch).localeCompare(String(b.batch)));
    modal(no + ' — ' + h.supplier + ' · ' + wh, (h.status === 'open' ? `<div class="row">${await skuSelect('plK')}${inp('plPr', 'Tgl produksi', '', 'date')}${inp('plE', 'ED*', '', 'date')}${inp('plG', 'No GR (SAP)')}${inp('plQ', 'Jumlah (ctn)*', '100', 'number')}${inp('plPer', 'Isi per pallet (ctn)*', '', 'number')}<button class="btn s" data-a="plAddLine" data-v="${esc(no)}">Tambah</button></div><p class="note" id="plPv" style="margin:8px 0 12px">Isi ED untuk melihat nomor batch.</p>` : '') +
      T(['SKU', 'Whs', 'Nama', 'Batch', 'No GR', 'Tgl produksi', 'ED', 'Jumlah'], lines.map(l => `<tr><td>${esc(l.sku)}</td><td>${esc(wh)}</td><td>${esc(l.products?.name || '')}</td><td>${esc(bno(l.sku, l.batch))}</td><td>${esc(l.gr_no || '—')}</td><td>${esc(l.production_date || '—')}</td><td>${esc(l.expiry)}</td><td class="num">${fmt(l.qty)}</td></tr>`)),
      null, '', '', '', 'wide');
    const K = document.getElementById('plPer');
    if (K) {
      K.value = perDef(v('plK'));
      document.getElementById('plK')?.addEventListener('change', () => { K.value = perDef(v('plK')); plSeq(); });
      document.getElementById('plE')?.addEventListener('change', plSeq);
      document.getElementById('plQ')?.addEventListener('input', plPrev);
      K.addEventListener('input', plPrev);
      plPrev();
    }
  };
  A.plEdit = async (no) => {
    try {
      const h = await api.getPackingList(no);
      if (h.status !== 'open') return toast('Packing List sudah dipakai, tidak bisa diedit.');
      const sup = await api.listActiveSuppliers();
      const names = sup.map(s => s.name); if (!names.includes(h.supplier)) names.unshift(h.supplier);
      const gr = (await api.packingListGr())[no] || [];
      modal('Edit Packing List ' + no,
        `<div class="row">${sel('plES', 'Pemasok*', names.map(n => { const s = sup.find(x => x.name === n); return [n, s && s.Whs ? s.Whs + ' — ' + n : n]; }))}${inp('plET', 'Tanggal input FG', h.doc_date, 'date')}${inp('plEG', 'No GR (SAP)', gr.length === 1 ? gr[0] : '')}</div><p class="note" style="margin:8px 0 12px">${gr.length > 1 ? 'GR saat ini: ' + esc(gr.join(', ')) + '. ' : ''}No GR yang diisi akan diterapkan ke semua baris item; kosongkan jika tidak ingin mengubah GR.</p>`,
        'Simpan', 'plSave', no);
      document.getElementById('plES').value = h.supplier;
    } catch (e) { rpcErr(e); }
  };
  A.plSave = async (no) => {
    const s = v('plES'), d = v('plET');
    if (!s) return toast('Pilih pemasok.');
    if (!d) return toast('Isi tanggal input FG.');
    try {
      await api.updatePackingList(no, s, d, v('plEG').trim());
      toast('Packing List diperbarui: ' + no);
      await A.mx?.(); go('pl', null);
    } catch (e) { rpcErr(e); }
  };
  A.plDel = async (no) => {
    if (!await askConfirm('Hapus Packing List', 'Hapus Packing List ' + no + ' beserta seluruh baris itemnya? Tindakan ini tidak bisa dibatalkan.', 'Hapus')) return;
    try { await api.deletePackingList(no); toast('Packing List dihapus: ' + no); go('pl', null); } catch (e) { rpcErr(e); }
  };
  A.plAddLine = async (no) => {
    const k = v('plK'), e = v('plE'), q = +v('plQ'), gr = v('plG').trim(), prod = v('plPr'), perRaw = v('plPer').trim(), per = parseInt(perRaw, 10);
    if (!k) return toast('Pilih produk.');
    if (!e) return toast('Isi ED.');
    if (!(q > 0) || !Number.isInteger(q)) return toast('Jumlah harus bilangan bulat lebih dari 0.');
    if (perRaw === '' || !(per >= 0)) return toast('Isi "Isi per pallet" (0 = tidak dipecah).');
    const parts = splitQty(q, per), y = ymd(e);
    const start = parseInt(await api.nextBatchSeq(k, y), 10) || 1;
    if (start + parts.length - 1 > 999) return toast('Nomor batch melebihi 999 untuk ED ini.');
    try { localStorage.setItem(perKey(k), String(per)); } catch (x) {}
    let done = 0;
    try {
      for (const qq of parts) { await api.addPackingListLine(no, k, y + '.' + pad3(start + done), prod, e, qq, gr); done++; }
      toast(done === 1 ? 'Item ditambahkan.' : done + ' pallet ditambahkan (batch ' + pad3(start) + ' s/d ' + pad3(start + done - 1) + ').');
    } catch (err) { rpcErr(err); if (done) toast(done + ' dari ' + parts.length + ' pallet sudah tersimpan, sisanya gagal.'); }
    await A.plV(no);
  };
}
