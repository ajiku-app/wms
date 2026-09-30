import { api } from '../api.js';
import { $, hd, T, tag, esc } from '../ui.js';

const LABEL = {
  LOGIN: 'Login',
  PL_CREATE: 'Buat Packing List', PL_ADD_LINE: 'Tambah item Packing List',
  IN_CREATE: 'Buat Inbound', GR_RECEIVE: 'Terima barang (Inbound)', IN_COMPLETE: 'Selesaikan Inbound',
  OUT_CREATE: 'Buat Outbound', FEFO_ALLOCATE: 'Alokasi FEFO', GI_PICK: 'Pick barang (Outbound)', OUT_COMPLETE: 'Selesaikan Outbound',
  STOCK_MOVE: 'Mutasi rak', OPNAME_CREATE: 'Buat Stok Opname', OPNAME_SET_LINE: 'Isi hitungan Opname', OPNAME_POST: 'Posting Opname',
  STOCK_ADJUST: 'Penyesuaian Stok', PUTAWAY: 'Putaway', HOLD_SET: 'Hold stok', HOLD_RELEASE: 'Lepas hold', RACK_SET_CAPACITY: 'Ubah kapasitas Rak',
  PRODUCT_ADD: 'Tambah Produk', RACK_ADD: 'Tambah Rak', RACK_SET_ACTIVE: 'Ubah kondisi Rak',
  SUPPLIER_ADD: 'Tambah Pemasok', CUSTOMER_ADD: 'Tambah Customer',
  USER_SET_ROLE: 'Atur role pengguna', USER_SET_ACTIVE: 'Aktifkan/nonaktifkan pengguna',
};

function detailText(row) {
  const d = row.detail || {};
  const parts = Object.entries(d).filter(([k]) => k !== 'sisa').map(([k, v]) => `${k}: ${v}`);
  return parts.join(', ');
}

export async function renderActivity() {
  $('#main').innerHTML = hd('Riwayat Aktivitas') +
    `<div class="note">Mencatat siapa melakukan apa dan kapan, termasuk setiap login. Admin dan supervisor melihat aktivitas semua orang; peran lain hanya melihat aktivitas sendiri.</div>
    <div class="card" id="actCard">Memuat…</div>`;
  const rows = await api.getActivityLog(150);
  $('#actCard').innerHTML = T(['Waktu', 'Pengguna', 'Role', 'Aksi', 'Dokumen', 'Detail'],
    rows.map(r => `<tr><td>${new Date(r.created_at).toLocaleString('id-ID')}</td><td>${esc(r.user_name || '—')}</td><td>${r.user_role ? tag('open', r.user_role) : '—'}</td><td>${esc(LABEL[r.action] || r.action)}</td><td>${esc(r.doc_no || '—')}</td><td class="l">${esc(detailText(r))}</td></tr>`));
}
