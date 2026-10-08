# API — Gudang FG Serena Indopapangan

Frontend tidak pernah bicara langsung ke database. Semua lewat dua jalur
REST yang disediakan otomatis oleh Supabase (PostgREST + RPC), dan **hanya
dua jalur ini** yang dianggap "API resmi" aplikasi:

- `GET /rest/v1/<tabel>` — baca data (SELECT), diatur oleh Row Level Security.
- `POST /rest/v1/rpc/<fungsi>` — jalankan aksi/perubahan data, lewat fungsi
  di `backend/functions.sql`.

Base URL: `https://kiqthmniiibofulbmbun.supabase.co`
Header wajib setiap request: `apikey: <anon key>` dan, setelah login,
`Authorization: Bearer <access_token>` (ditangani otomatis oleh `supabase-js`
di `frontend/js/api.js` — daftar di bawah ini bukan untuk dipanggil manual,
tapi sebagai dokumentasi kontrak).

## Autentikasi
| Aksi | Endpoint | Keterangan |
|---|---|---|
| Daftar | `POST /auth/v1/signup` | Membuat akun baru. Trigger `handle_new_user` otomatis membuat baris `profiles` dengan `role = null`. |
| Masuk | `POST /auth/v1/token?grant_type=password` | Login email + kata sandi. |
| Keluar | client-side | Menghapus sesi. |

Akun baru **tidak bisa mengakses data apa pun** sampai seorang admin
memanggil `wms_set_role`.

## Baca data (REST, method GET)
| Tabel | Dibatasi untuk role | Dipakai di |
|---|---|---|
| `products`, `racks`, `suppliers`, `customers`, `stock` | siapa pun yang sudah punya role | Master, Stok, Dashboard |
| `packing_lists`, `packing_list_lines` | inbound, admin, supervisor | Packing List |
| `inbound_docs`, `inbound_lines` | inbound, admin, supervisor | Inbound |
| `outbound_docs`, `outbound_picks`, `outbound_items` | picker, admin, supervisor | Outbound |
| `opname_docs`, `opname_lines` | admin, supervisor | Stok Opname |
| `stock_movements` | admin, supervisor | Report, Mutasi, Penyesuaian |
| `profiles` | siapa pun yang sudah punya role (lihat semua nama untuk PIC) | Users Management |
| `activity_log` | **tidak ada** — RLS aktif tanpa satu policy pun. Tabel ini tertutup total, bahkan untuk admin. Satu-satunya jalan baca lewat RPC `wms_get_activity_log`. | — |

## Aksi / perubahan data (RPC, method POST)
| Fungsi | Parameter | Siapa boleh panggil | Dipakai di |
|---|---|---|---|
| `wms_set_role` | `p_user, p_role` | admin, supervisor | Users Management |
| `wms_user_set_active` | `p_user, p_active` | admin, supervisor | Users Management |
| `wms_product_add` | `p_sku, p_name, p_cpp` | admin, supervisor | Master Produk |
| `wms_rack_add` | `p_code, p_zone, p_capacity` (default 0) — kode wajib `ZONA-BIM-LEVEL` (mis. `A-01-03`) | admin, supervisor | Master Rak |
| `wms_rack_set_capacity` | `p_code, p_capacity` | admin, supervisor | Master Rak |
| `wms_rack_set_active` | `p_code, p_active` | admin, supervisor | Master Rak |
| `wms_supplier_add` | `p_name` | inbound, admin, supervisor | Master Pemasok |
| `wms_customer_add` | `p_name, p_phone, p_address` | picker, admin, supervisor | Master Customer |
| `wms_pl_create` | `p_no, p_supplier, p_doc_date` | inbound, admin, supervisor | Packing List |
| `wms_pl_add_line` | `p_pl, p_sku, p_batch, p_production, p_expiry, p_qty` | inbound, admin, supervisor | Packing List |
| `wms_inbound_create` | `p_no, p_pl` | inbound, admin, supervisor | Inbound |
| `wms_inbound_receive_line` | `p_doc, p_sku, p_batch, p_qty, p_rack` | inbound, admin, supervisor | Inbound — menambah stok |
| `wms_inbound_complete` | `p_doc` | inbound, admin, supervisor | Inbound |
| `wms_outbound_create` | `p_no, p_customer, p_phone, p_address, p_whs` (opsional) | picker, admin, supervisor | Outbound |
| `fefo_allocate` | `p_doc, p_sku, p_qty` → return sisa yang tak terpenuhi (melewati stok hold, kedaluwarsa, dan GR-STAGING) | picker, admin, supervisor | Outbound — alokasi FEFO |
| `wms_pick` | `p_doc, p_sku, p_batch, p_rack, p_qty` | picker, admin, supervisor | Outbound — catat pick, kurangi stok |
| `wms_outbound_set_items` | `p_doc, p_items` (`[{sku, qty}]`) | picker, admin, supervisor | Outbound |
| `wms_outbound_complete` | `p_doc, p_allow_short` (default false), **`p_load_start, p_load_end` (timestamptz), `p_vehicle, p_expedition, p_loaders` (text) — semua WAJIB sejak v2.0.20**. Ditolak bila picking list kosong, picking belum lengkap, atau pesanan (`outbound_items`) belum terpenuhi; `p_allow_short=true` hanya berlaku untuk admin/supervisor. Data muat disimpan di `outbound_docs` (`load_start, load_end, vehicle_no, expedition, loaders`) | picker, admin, supervisor | Outbound |
| `wms_move` | `p_sku, p_batch, p_from, p_to, p_qty` | inbound, admin, supervisor | Mutasi |
| `wms_opname_create` | `p_no, p_sku, p_counter` | admin, supervisor | Stok Opname |
| `wms_opname_set_line` | `p_doc, p_batch, p_rack, p_physical` | admin, supervisor | Stok Opname |
| `wms_opname_post` | `p_doc` → return `{selisih}` | admin, supervisor | Stok Opname |
| `wms_putaway` | `p_sku, p_batch, p_rack, p_qty` | inbound, admin, supervisor | Putaway |
| `wms_next_batch_seq` | `p_sku, p_ymd` → nomor urut batch berikutnya | inbound, admin, supervisor | Packing List |
| `wms_hold_set` / `wms_hold_release` | `p_sku, p_batch, p_rack, p_qty, p_reason, p_note` / `p_id` | admin, supervisor | Hold & Karantina |
| `wms_adjust` | `p_sku, p_batch, p_rack, p_new_qty, p_reason` | admin, supervisor | Penyesuaian Stok |

Catatan v2.0.17: kapasitas rak (`racks.capacity`) kini dalam **pallet per bin loc** (1 pallet = 1 baris stok SKU+batch). `wms_move` dan `wms_putaway` selalu memindahkan satu pallet utuh (`p_qty` null atau sama dengan isi pallet), menolak pallet yang di-hold atau sudah dialokasikan outbound, dan menolak bila bin tujuan penuh. Barang inbound hanya boleh masuk `GR-STAGING` (dijaga trigger `trg_guard_movement`). `wms_freeze_set(p_active, p_note)` (admin/supervisor) menyalakan/mematikan FREEZE: selama aktif, semua penulisan `stock_movements` ditolak kecuali posting selisih opname yang masih terbuka. Status dibaca dari tabel `wms_freeze`.

Catatan v2.0.13: `wms_inbound_receive_line` menolak jumlah di atas Jumlah PL dan, bila diterima langsung ke rak (bukan `GR-STAGING`), menolak melebihi kapasitas rak. `wms_pick` menolak batch kedaluwarsa. `wms_opname_post` menghitung selisih terhadap stok saat posting.

Semua fungsi mengembalikan `jsonb`, minimal `{"ok": true}` bila sukses, dan
melempar error (HTTP 400 dari PostgREST) dengan pesan berbahasa Indonesia
bila gagal — pesan ini yang ditangkap dan ditampilkan `rpcErr()` di frontend.

## Menambah endpoint baru
1. Buat file migrasi dan tulis juga fungsinya di `backend/functions.sql` (sumber kebenaran; cek dengan `export-snapshot.sql` query 6).
2. Tambahkan satu baris di `frontend/js/api.js` yang memanggilnya.
3. Panggil `api.namaFungsi(...)` dari file `views/*.js` — jangan pernah
   memanggil `sb.rpc()`/`sb.from()` langsung dari file view.
