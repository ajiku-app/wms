-- ============================================================
-- MIGRASI v2.0.18 — Hardening hak eksekusi (menutup temuan K2). Jalankan SEKALI setelah v2.0.17. Aman diulang.
-- Masalah: migrate_v2_0_16 menjalankan loop "beri authenticated" ke semua fungsi, sehingga fungsi INTERNAL
-- ikut terbuka. Akibat nyata: wms_log() bisa dipanggil user mana pun lewat RPC (memalsukan log aktivitas).
-- Fungsi internal tetap bekerja karena dipanggil oleh fungsi SECURITY DEFINER (berjalan sebagai pemilik).
-- ============================================================
begin;
REVOKE EXECUTE ON FUNCTION public.handle_new_user()        FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.wms_log_login()          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable()        FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.wms_guard_movement()     FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.wms_log(text,text,jsonb) FROM PUBLIC, anon, authenticated;
commit;
notify pgrst, 'reload schema';

-- Cek (harus: semua kolom anon = false; authenticated = false untuk 5 fungsi di atas)
select p.proname, has_function_privilege('anon', p.oid, 'EXECUTE') as anon,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated
from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
  and (p.proname in ('handle_new_user','wms_log_login','rls_auto_enable','wms_guard_movement','wms_log')
       or has_function_privilege('anon', p.oid, 'EXECUTE')) order by 1;
