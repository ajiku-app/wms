-- ============================================================
-- MIGRASI v2.0.14 — Realtime untuk Scan WMS v1.0.3
-- Memastikan 7 tabel yang dibaca Scan terdaftar di publikasi supabase_realtime.
-- Aman diulang (tabel yang sudah terdaftar dilewati). Tidak mengubah data.
-- Hak baca event mengikuti RLS: pengguna hanya menerima perubahan pada baris yang boleh dia SELECT.
-- ============================================================
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['inbound_docs','inbound_lines','outbound_docs','outbound_picks','stock','stock_holds','racks'] LOOP
    IF to_regclass('public.' || t) IS NULL THEN
      RAISE WARNING 'Tabel public.% tidak ada, dilewati', t;
    ELSIF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename=t) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END $$;

-- Cek hasil: semua baris harus 'OK'
SELECT v.t AS tabel,
       CASE WHEN EXISTS (SELECT 1 FROM pg_publication_tables p WHERE p.pubname='supabase_realtime' AND p.schemaname='public' AND p.tablename=v.t)
            THEN 'OK' ELSE 'BELUM TERDAFTAR' END AS status
FROM (VALUES ('inbound_docs'),('inbound_lines'),('outbound_docs'),('outbound_picks'),('stock'),('stock_holds'),('racks')) v(t)
ORDER BY 1;
