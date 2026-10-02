-- ============================================================
-- MIGRASI v2.0.16 — Cabut hak EXECUTE 'anon' dari fungsi public
-- Temuan dari ekspor hak eksekusi live: 16 fungsi masih bisa dipanggil tanpa login (anon), antara lain
-- wms_hold_set, wms_hold_release, wms_pl_delete, wms_putaway, wms_stock_page, wms_dashboard.
-- Setiap fungsi itu menolak pengguna tanpa role di baris pertamanya, jadi tidak ada kebocoran data yang terbukti,
-- tetapi anon key bersifat publik: lapisan pertama sebaiknya menutup akses sama sekali (defense in depth).
-- Aplikasi WMS & Scan hanya memanggil RPC setelah login (authenticated), sehingga tidak ada perubahan perilaku.
-- Aman diulang. Tidak mengubah data. BACKUP tetap disarankan.
-- ============================================================
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS fn
           FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
             AND has_function_privilege('anon', p.oid, 'EXECUTE')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', r.fn);
    -- pastikan pengguna login tetap bisa memanggil
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.fn);
  END LOOP;
END $$;

-- Fungsi baru di masa depan tidak otomatis terbuka untuk anon
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon;

-- Cek hasil: kolom anon harus 'false' di semua baris (status OK)
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS argumen,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated,
       CASE WHEN has_function_privilege('anon', p.oid, 'EXECUTE') THEN 'PERIKSA' ELSE 'OK' END AS status
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
ORDER BY (has_function_privilege('anon', p.oid, 'EXECUTE')) DESC, 1;
