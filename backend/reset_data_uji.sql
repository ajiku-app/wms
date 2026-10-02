-- ============================================================
-- RESET DATA UJI — MENGHAPUS SEMUA DATA TRANSAKSI. HANYA UNTUK MASA TRIAL. TIDAK BISA DIBATALKAN.
-- Dihapus : stok, buku besar pergerakan, hold, Packing List, Inbound, Outbound (item & picking), Opname.
-- DIPERTAHANKAN: produk, rak (beserta kapasitas), pemasok, customer, user/profil, status freeze, log aktivitas.
-- Semua nomor urut (batch YYYYMMDD.NNN) kembali ke .001 karena dihitung dari tabel-tabel di atas.
-- Jalankan di Supabase SQL Editor. Pastikan TIDAK ADA operator yang sedang bertransaksi dan antrian HP sudah kosong.
-- ============================================================
begin;
truncate table
  public.outbound_picks, public.outbound_items, public.outbound_docs,
  public.opname_lines, public.opname_docs,
  public.inbound_lines, public.inbound_docs,
  public.packing_list_lines, public.packing_lists,
  public.stock_holds, public.stock_movements, public.stock
restart identity;
-- Opsional (hapus tanda -- bila log aktivitas uji juga ingin dibersihkan):
-- truncate table public.activity_log restart identity;
commit;

-- Cek: semua harus 0
select (select count(*) from stock) as stock, (select count(*) from stock_movements) as movements,
       (select count(*) from packing_list_lines) as pl_lines, (select count(*) from inbound_docs) as inbound,
       (select count(*) from outbound_docs) as outbound;
-- Cek aturan: index nomor pallet unik harus ada
select indexname from pg_indexes where indexname = 'ux_pl_lines_sku_batch_pallet';
