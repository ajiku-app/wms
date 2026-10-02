-- ============================================================
-- EKSPOR SNAPSHOT DATABASE LIVE (hanya membaca; aman dijalankan di produksi)
-- Jalankan tiap query di Supabase SQL Editor, lalu "Export > CSV" hasilnya (atau salin hasilnya).
-- Dipakai untuk membuat snapshot bersih (menutup temuan K2) dan mendeteksi fungsi ganda/usang.
-- ============================================================

-- 1) Semua fungsi di schema public (definisi lengkap)
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS argumen,
       pg_get_functiondef(p.oid) AS definisi
FROM pg_proc p
WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
ORDER BY p.proname, 2;

-- 2) Constraint: primary key, unique, foreign key, check
SELECT conrelid::regclass AS tabel, conname, contype, pg_get_constraintdef(oid) AS definisi
FROM pg_constraint WHERE connamespace = 'public'::regnamespace ORDER BY 1, 2;

-- 3) Index
SELECT tablename, indexname, indexdef FROM pg_indexes WHERE schemaname = 'public' ORDER BY 1, 2;

-- 4) Hak eksekusi fungsi (siapa boleh memanggil)
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS argumen,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anon,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated
FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f' ORDER BY 1, 2;

-- 5) Trigger
SELECT event_object_table AS tabel, trigger_name, action_timing, event_manipulation, action_statement
FROM information_schema.triggers WHERE trigger_schema = 'public' ORDER BY 1, 2;
