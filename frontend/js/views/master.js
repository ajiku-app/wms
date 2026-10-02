import { api } from '../api.js';
import { $, hd, T, bar, bt, ic, tag, inp, v, modal, toast, rpcErr, fmt, askText, esc } from '../ui.js';

export async function renderMProduk() {
  const data = await api.listProducts();
  $('#main').innerHTML = hd('Master — Produk') + `<div class="card">${bar(bt('prM', '+ Tambah'))}${T(['SKU', 'Nama', 'Pcs/carton', 'Status'], data.map(p => `<tr><td>${esc(p.sku)}</td><td>${esc(p.name)}</td><td class="num">${esc(p.pcs_per_ctn)}</td><td>${tag(p.active, p.active ? 'Aktif' : 'Nonaktif')}</td></tr>`))}</div>`;
}
export async function renderMRak() {
  const data = await api.listRacks();
  // Filter baris rak berdasarkan huruf depan kode (A … P dst), diambil dari data yang ada
  const letters = [...new Set(data.map(r => String(r.code || '').charAt(0).toUpperCase()).filter(Boolean))].sort();
  let f = window.__rkF || '';
  if (f && !letters.includes(f)) f = '';
  const rowsHtml = () => data.filter(r => !f || String(r.code).toUpperCase().startsWith(f)).map(r => `<tr><td>${esc(r.code)}</td><td>${esc(r.zone || '—')}</td><td class="num">${r.capacity ? fmt(r.capacity) : '—'}</td><td>${tag(r.active ? 'Bagus' : 'Rusak')}</td><td>${ic('rkTg', r.code + '|' + (!r.active), 'Ubah kondisi')} ${ic('rkCap', r.code, 'Kapasitas')}</td></tr>`);
  const chips = () => `<div class="chips"><button data-f="" class="${f ? '' : 'on'}">Semua (${data.length})</button>${letters.map(l => `<button data-f="${esc(l)}" class="${f === l ? 'on' : ''}">${esc(l)} (${data.filter(r => String(r.code).toUpperCase().startsWith(l)).length})</button>`).join('')}</div>`;
  $('#main').innerHTML = hd('Master — Rak') + `<div class="card">${bar(bt('rkM', '+ Tambah'))}<div id="rkC">${chips()}</div><div id="rkT">${T(['Kode Rak', 'Zona', 'Kapasitas (pallet)', 'Kondisi', 'Aksi'], rowsHtml())}</div></div>`;
  $('#rkC').onclick = (e) => {
    const b = e.target.closest('button[data-f]'); if (!b) return;
    f = window.__rkF = b.dataset.f;
    $('#rkC').innerHTML = chips(); $('#rkT').innerHTML = T(['Kode Rak', 'Zona', 'Kapasitas (pallet)', 'Kondisi', 'Aksi'], rowsHtml());
  };
}
export async function renderMPemasok() {
  const data = await api.listSuppliers();
  $('#main').innerHTML = hd('Master — Pemasok') + `<div class="card">${bar(bt('spM', '+ Tambah'))}${T(['Whs', 'Nama Pemasok', 'Status'], data.map(s => `<tr><td>${esc(s.Whs || '—')}</td><td>${esc(s.name)}</td><td>${tag(s.active, s.active ? 'Aktif' : 'Nonaktif')}</td></tr>`))}</div>`;
}
export async function renderMCust() {
  const data = await api.listCustomers();
  $('#main').innerHTML = hd('Master — Customer') + `<div class="card">${bar(bt('cuM', '+ Tambah'))}${T(['Nama Customer', 'Telepon', 'Alamat', 'Status'], data.map(c => `<tr><td>${esc(c.name)}</td><td>${esc(c.phone || '—')}</td><td>${esc(c.address || '—')}</td><td>${tag(c.active, c.active ? 'Aktif' : 'Nonaktif')}</td></tr>`))}</div>`;
}

export function registerMasterActions(A, go) {
  A.prM = () => modal('Tambah Produk', inp('f_sku', 'SKU*') + inp('f_nama', 'Nama Produk*') + inp('f_cpp', 'Pcs / carton*', '1', 'number'), 'Simpan', 'prAdd');
  A.prAdd = async () => {
    const sku = v('f_sku').trim(), nama = v('f_nama').trim(), cpp = +v('f_cpp');
    if (!sku || !nama) return toast('Lengkapi SKU dan nama.');
    try { await api.addProduct(sku, nama, cpp); A.mx(); toast('Produk ditambahkan.'); go('mProduk'); } catch (e) { rpcErr(e); }
  };
  A.rkM = () => modal('Tambah Rak', inp('f_kode', 'Kode rak*') + inp('f_zone', 'Zona') + inp('f_cap', 'Kapasitas (pallet per bin, 0 = tidak dibatasi)', '3', 'number'), 'Simpan', 'rkAdd');
  A.rkAdd = async () => {
    const c = v('f_kode').trim(); if (!c) return toast('Isi kode rak.');
    try { await api.addRack(c, v('f_zone'), Math.max(0, +v('f_cap') || 0)); A.mx(); toast('Rak ditambahkan.'); go('mRak'); } catch (e) { rpcErr(e); }
  };
  A.rkTg = async (s) => {
    const [code, act] = s.split('|');
    try { await api.setRackActive(code, act === 'true'); go('mRak'); } catch (e) { rpcErr(e); }
  };
  A.rkCap = async (code) => {
    const t = await askText('Kapasitas ' + code, 'Kapasitas (pallet per bin)', 'Simpan', 'mis. 3'); if (t === null) return;
    const n = parseInt(t, 10); if (!(n >= 0)) return toast('Isi angka 0 atau lebih.');
    try { await api.setRackCapacity(code, n); toast('Kapasitas disimpan.'); go('mRak'); } catch (e) { rpcErr(e); }
  };
  A.spM = () => modal('Tambah Pemasok', inp('f_nm', 'Nama pemasok*'), 'Simpan', 'spAdd');
  A.spAdd = async () => {
    const n = v('f_nm').trim(); if (!n) return toast('Isi nama.');
    try { await api.addSupplier(n); A.mx(); toast('Tersimpan.'); go('mPemasok'); } catch (e) { rpcErr(e); }
  };
  A.cuM = () => modal('Tambah Customer', inp('f_nm', 'Nama customer*') + inp('f_tp', 'No. Telepon') + inp('f_al', 'Alamat'), 'Simpan', 'cuAdd');
  A.cuAdd = async () => {
    const n = v('f_nm').trim(); if (!n) return toast('Isi nama.');
    try { await api.addCustomer(n, v('f_tp'), v('f_al')); A.mx(); toast('Tersimpan.'); go('mCust'); } catch (e) { rpcErr(e); }
  };
}
