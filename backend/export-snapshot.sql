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

-- 6) VERIFIKASI K2: bandingkan database live dengan functions.sql (47 fungsi yang diharapkan)
--    Hasil yang baik: 0 baris. "ADA DI LIVE, TIDAK DI FILE" = fungsi usang/ganda yang harus ditinjau/dihapus.
--    "ADA DI FILE, TIDAK DI LIVE" = migrasi belum dijalankan.
WITH expected(proname, argtypes) AS (VALUES
  ('fefo_allocate','text,text,int'),
  ('handle_new_user',''),
  ('rls_auto_enable',''),
  ('wms_adjust','text,text,text,int,text'),
  ('wms_aging','int'),
  ('wms_customer_add','text,text,text'),
  ('wms_dashboard',''),
  ('wms_freeze_set','boolean,text'),
  ('wms_get_activity_log','int,timestamptz'),
  ('wms_guard_movement',''),
  ('wms_held','text,text,text'),
  ('wms_hold_list',''),
  ('wms_hold_release','bigint'),
  ('wms_hold_set','text,text,text,int,text,text'),
  ('wms_inbound_complete','text'),
  ('wms_inbound_create','text,text'),
  ('wms_inbound_receive_line','text,text,text,int,text,timestamptz,text'),
  ('wms_is_frozen',''),
  ('wms_log','text,text,jsonb'),
  ('wms_log_login',''),
  ('wms_move','text,text,text,text,int,timestamptz,text'),
  ('wms_next_batch_seq','text,text'),
  ('wms_opname_create','text,text,text'),
  ('wms_opname_post','text'),
  ('wms_opname_set_line','text,text,text,int'),
  ('wms_outbound_complete','text,boolean,timestamptz,timestamptz,text,text,text'),
  ('wms_outbound_create','text,text,text,text,text'),
  ('wms_outbound_set_items','text,jsonb'),
  ('wms_pick','text,text,text,text,int,timestamptz,text'),
  ('wms_pl_add_line','text,text,text,date,date,int,text'),
  ('wms_pl_create','text,text,date'),
  ('wms_pl_delete','text'),
  ('wms_pl_update','text,text,date,text'),
  ('wms_product_add','text,text,int'),
  ('wms_putaway','text,text,text,int'),
  ('wms_rack_add','text,text,int'),
  ('wms_rack_load',''),
  ('wms_rack_pallets','text'),
  ('wms_rack_set_active','text,boolean'),
  ('wms_rack_set_capacity','text,int'),
  ('wms_role',''),
  ('wms_set_role','uuid,text'),
  ('wms_staging_pending',''),
  ('wms_stock_page','text,text,int,int,text,text'),
  ('wms_supplier_add','text'),
  ('wms_today',''),
  ('wms_user_set_active','uuid,boolean')
), live AS (
  SELECT p.proname, p.oid,
    replace(replace(replace(pg_get_function_identity_arguments(p.oid), 'integer','int'), 'timestamp with time zone','timestamptz'), 'character varying','text') AS args
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prokind IN ('f','p')
), live_t AS (
  SELECT proname,
    (SELECT string_agg(split_part(trim(a), ' ', 2), ',' ORDER BY ord)
       FROM unnest(string_to_array(args, ',')) WITH ORDINALITY AS u(a, ord)) AS argtypes
  FROM live
)
SELECT 'ADA DI LIVE, TIDAK DI FILE' AS status, l.proname, l.argtypes FROM live_t l
  LEFT JOIN expected e ON e.proname = l.proname AND coalesce(e.argtypes,'') = coalesce(l.argtypes,'') WHERE e.proname IS NULL
UNION ALL
SELECT 'ADA DI FILE, TIDAK DI LIVE', e.proname, e.argtypes FROM expected e
  LEFT JOIN live_t l ON e.proname = l.proname AND coalesce(e.argtypes,'') = coalesce(l.argtypes,'') WHERE l.proname IS NULL
ORDER BY 1, 2;
