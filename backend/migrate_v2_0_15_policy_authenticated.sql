-- ============================================================
-- MIGRASI v2.0.15 — Policy baca hanya untuk peran 'authenticated'
-- Menyelaraskan 9 policy yang di database live masih berperan 'public' (termasuk anon)
-- dengan 8 policy lain yang sudah 'authenticated'. Tidak ada perubahan perilaku untuk pengguna login
-- (anon sebelumnya sudah ditolak karena wms_role() bernilai NULL). Aman diulang. Tidak mengubah data.
-- ============================================================
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('profiles','p_profiles'),('stock_holds','p_holds'),('outbound_items','p_out_items'),('suppliers','p_suppliers'),
    ('customers','p_customers'),('packing_lists','p_pl'),('packing_list_lines','p_pl_lines'),
    ('opname_docs','p_opname_docs'),('opname_lines','p_opname_lines')) v(t,p)
  LOOP
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename=r.t AND policyname=r.p) THEN
      EXECUTE format('ALTER POLICY %I ON public.%I TO authenticated', r.p, r.t);
    ELSE
      RAISE WARNING 'Policy % pada % tidak ditemukan, dilewati', r.p, r.t;
    END IF;
  END LOOP;
END $$;

-- Cek hasil: kolom 'roles' semua baris harus {authenticated}
SELECT tablename, policyname, roles::text AS roles,
       CASE WHEN roles = '{authenticated}' THEN 'OK' ELSE 'PERIKSA' END AS status
FROM pg_policies WHERE schemaname='public' ORDER BY 1,2;
