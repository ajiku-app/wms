-- Auto refresh (Realtime): daftarkan tabel ke publikasi supabase_realtime.
-- Jalankan SEKALI di Supabase SQL Editor. Aman diulang (tabel yang sudah terdaftar dilewati).
-- Hak baca event mengikuti RLS: pengguna hanya menerima perubahan pada baris yang boleh dia SELECT.
-- activity_log sengaja tidak didaftarkan (hanya bisa dibaca lewat fungsi); halaman Riwayat Aktivitas
-- tetap ikut ter-refresh karena setiap aksi juga mengubah tabel lain.
do $$
declare t text;
begin
  foreach t in array array[
    'stock','stock_movements','packing_lists','packing_list_lines','inbound_docs','inbound_lines',
    'outbound_docs','outbound_picks','opname_docs','opname_lines','racks','products','suppliers','customers','profiles'
  ] loop
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
