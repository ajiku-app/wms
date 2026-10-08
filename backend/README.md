# Backend — Gudang FG Serena Indopapangan

Backend aplikasi ini **adalah project Supabase** (Postgres + Auth + REST API
otomatis), bukan server Node/Express terpisah. Tiga file di folder ini adalah
salinan persis dari apa yang berjalan di project Supabase `wms`:

| File | Isi |
|---|---|
| `schema.sql` | Semua tabel: master (produk, rak, pemasok, customer) dan transaksi (packing list, inbound, outbound, stok, opname, buku besar pergerakan stok). |
| `policies.sql` | Row Level Security. Tabel hanya bisa **dibaca** langsung, dan hanya oleh pengguna yang login dan sudah diberi role. |
| `functions.sql` | (sumber kebenaran, konsolidasi v2.0.18) Semua **logika bisnis** (terima barang, FEFO, kirim barang, mutasi, opname, penyesuaian, log aktivitas). Ini yang sebenarnya menjadi "API" aplikasi — lihat `../API.md`. |

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
| 3 | `functions_initial.sql` | fungsi awal (**hanya bootstrap database baru**; sebagian digantikan migrasi di bawah) |
| 4 | `migrate_gr_batch.sql` | No GR + format batch `YYYYMMDD.NNN` |
| 5 | `migrate_wms_v2.sql` | putaway, hold, kapasitas, dashboard, aging |
| 6 | `migrate_v2_0_11_batas_terima.sql` | terima tidak boleh melebihi PL |
| 7 | `migrate_v2_0_12_outbound_items.sql` | `outbound_items` + `wms_outbound_set_items` |
| 8 | `migrate_pl_edit_delete.sql` | edit/hapus Packing List |
| 9 | `migrate_v2_0_13_sinkron.sql` | **perbaikan sinkronisasi** (whs, picker FEFO, validasi DO, kapasitas, opname, batch) |
| 10 | `realtime.sql` | Realtime |
| 11 | `migrate_v2_0_14_realtime_scan.sql` | tabel realtime untuk Scan |
| 12 | `migrate_v2_0_15_policy_authenticated.sql` | policy baca hanya `authenticated` |
| 13 | `migrate_v2_0_16_cabut_hak_anon.sql` | cabut EXECUTE `anon` |
| 14 | `migrate_v2_0_17_pallet_freeze_staging.sql` | **freeze opname, inbound wajib staging, kapasitas rak per pallet, pindah/putaway per pallet, pallet tidak ganda** |
| 15 | `migrate_v2_0_18_hardening_k2.sql` | **hak eksekusi:** fungsi internal (`wms_log`, trigger) tertutup dari RPC (mencegah pemalsuan log) |
| 16 | `migrate_v2_0_19_receive_staging.sql` | penerimaan inbound hanya ke GR-STAGING (pesan jelas, logika kapasitas ctn lama dihapus) |
| 17 | `migrate_v2_0_20_outbound_muat.sql` | **data muat saat close outbound:** waktu mulai/selesai muat, no. kendaraan, ekspedisi, petugas muat (wajib). Pasang Scan v1.0.5 |
| 18 | `functions.sql` | **sumber kebenaran fungsi** (konsolidasi v2.0.17–v2.0.20, 47 fungsi). Opsional di akhir untuk database baru; di database live jalankan hanya setelah diverifikasi dengan `export-snapshot.sql` query 6 |

Utilitas: `reset_data_uji.sql` — mengosongkan data transaksi (master dipertahankan); **hanya untuk masa trial**.

Aturan: `functions_initial.sql` **hanya untuk database baru**, jangan dijalankan di database yang berjalan. Folder `supabase-arsip/` di repo scan sudah dihapus.
Setiap fungsi baru/ubahan wajib: (1) dibuatkan file migrasi, (2) ditulis juga di `functions.sql`. Verifikasi berkala: jalankan `export-snapshot.sql` query 6 (hasil harus 0 baris).
Nilai `suppliers."Whs"` (kode warehouse, mis. FG-01) diisi manual, mis. `update suppliers set "Whs"='FG-01' where name='...';`
