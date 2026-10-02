# Backend — Gudang FG Serena Indopapangan

Backend aplikasi ini **adalah project Supabase** (Postgres + Auth + REST API
otomatis), bukan server Node/Express terpisah. Tiga file di folder ini adalah
salinan persis dari apa yang berjalan di project Supabase `wms`:

| File | Isi |
|---|---|
| `schema.sql` | Semua tabel: master (produk, rak, pemasok, customer) dan transaksi (packing list, inbound, outbound, stok, opname, buku besar pergerakan stok). |
| `policies.sql` | Row Level Security. Tabel hanya bisa **dibaca** langsung, dan hanya oleh pengguna yang login dan sudah diberi role. |
| `functions.sql` | Semua **logika bisnis** (terima barang, FEFO, kirim barang, mutasi, opname, penyesuaian, log aktivitas). Ini yang sebenarnya menjadi "API" aplikasi — lihat `../API.md`. |

## Log aktivitas (activity_log)

Setiap fungsi aksi mencatat satu baris ke `activity_log` lewat `wms_log(...)`,
dan setiap login berhasil tercatat otomatis lewat trigger `wms_log_login`.
Tabel ini sengaja tidak punya policy SELECT sama sekali — tertutup total dari
REST langsung, bahkan untuk admin. Satu-satunya jalan membacanya adalah RPC
`wms_get_activity_log()`, yang membatasi sendiri: admin/supervisor melihat
semua baris, role lain hanya melihat baris miliknya sendiri.

## Kenapa tidak ada tabel INSERT/UPDATE policy?

Sengaja. Satu-satunya jalan mengubah data adalah lewat fungsi di `functions.sql`
(ditandai `SECURITY DEFINER`). Setiap fungsi mengecek peran pengguna di baris
pertama dan menolak kalau tidak berwenang. Ini mencegah frontend (atau siapa pun
yang tahu URL & anon key) mengubah data lewat jalur lain selain aturan bisnis
yang sudah ditentukan.

## Memindahkan backend ini ke project Supabase lain

```bash
# lewat Supabase CLI, di project baru:
supabase db execute -f schema.sql
supabase db execute -f policies.sql
supabase db execute -f functions.sql
```
Atau tempel isinya satu per satu ke **SQL Editor** di dashboard Supabase.

## Rak wajib: GR-STAGING

Beberapa fungsi (`wms_inbound_receive_line`, `fefo_allocate`) mengasumsikan ada
satu rak dengan kode `GR-STAGING` sebagai area transit. Baris ini sudah dibuat
otomatis di akhir `schema.sql` — jangan dihapus.

## Catatan: fungsi `wms_receive` sudah tidak ada

Versi lama backend ini pernah punya fungsi `wms_receive` (terima barang
langsung tanpa Packing List). Fungsi itu **sudah dihapus** dari database oleh
proses pengerasan keamanan otomatis Supabase. Aplikasi ini tidak pernah
memakainya — alur inbound selalu lewat Packing List → `wms_inbound_create` →
`wms_inbound_receive_line` — jadi tidak ada dampak.

## Urutan eksekusi di database BARU (v2.0.13)

| # | File | Keterangan |
|---|---|---|
| 1 | `schema.sql` | tabel dasar |
| 2 | `policies.sql` | RLS |
| 3 | `functions.sql` | fungsi awal (snapshot; sebagian digantikan migrasi di bawah) |
| 4 | `migrate_gr_batch.sql` | No GR + format batch `YYYYMMDD.NNN` |
| 5 | `migrate_wms_v2.sql` | putaway, hold, kapasitas, dashboard, aging |
| 6 | `migrate_v2_0_11_batas_terima.sql` | terima tidak boleh melebihi PL |
| 7 | `migrate_v2_0_12_outbound_items.sql` | `outbound_items` + `wms_outbound_set_items` |
| 8 | `migrate_pl_edit_delete.sql` | edit/hapus Packing List |
| 9 | `migrate_v2_0_13_sinkron.sql` | **perbaikan sinkronisasi** (whs, picker FEFO, validasi DO, kapasitas, opname, batch) |
| 10 | `realtime.sql` | Realtime |

Aturan: **jangan menjalankan ulang `functions.sql`** di database yang sudah berjalan, dan
**jangan menjalankan folder `supabase-arsip/` dari repo scan-wms** (versi lama, menimpa fungsi di atas).
Nilai `suppliers."Whs"` (kode warehouse, mis. FG-01) diisi manual, mis. `update suppliers set "Whs"='FG-01' where name='...';`
