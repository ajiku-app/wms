-- Migrasi v2.0.12: simpan item pesanan Outbound di database
-- (sebelumnya hanya di localStorage perangkat, sehingga hilang di perangkat lain).
-- Jalankan SEKALI di Supabase SQL Editor (aman dijalankan ulang).
-- Tidak mengubah wms_outbound_create; item disimpan lewat fungsi baru wms_outbound_set_items.

CREATE TABLE IF NOT EXISTS public.outbound_items(
  doc_no varchar NOT NULL REFERENCES public.outbound_docs(no),
  sku varchar NOT NULL REFERENCES public.products(sku),
  qty integer NOT NULL CHECK (qty > 0),
  PRIMARY KEY (doc_no, sku)
);

ALTER TABLE public.outbound_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_out_items ON public.outbound_items;
CREATE POLICY p_out_items ON public.outbound_items FOR SELECT
  USING (wms_role() = any(array['picker','admin','supervisor']));

-- Mengganti seluruh item pesanan suatu dokumen outbound yang masih 'open'.
-- p_items: [{"sku":"ABC","qty":10}, ...] (SKU yang sama dijumlahkan)
CREATE OR REPLACE FUNCTION public.wms_outbound_set_items(p_doc text, p_items jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_n integer;
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('picker','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF NOT EXISTS (SELECT 1 FROM outbound_docs WHERE no = p_doc AND status = 'open') THEN
    RAISE EXCEPTION 'Outbound tidak ditemukan atau sudah selesai';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Item pesanan wajib diisi';
  END IF;
  DELETE FROM outbound_items WHERE doc_no = p_doc;
  INSERT INTO outbound_items(doc_no, sku, qty)
    SELECT p_doc, x.sku, sum(x.qty)::int
    FROM jsonb_to_recordset(p_items) AS x(sku text, qty integer)
    WHERE x.qty > 0 GROUP BY x.sku;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM wms_log('OUT_ITEMS', p_doc, jsonb_build_object('items', v_n));
  RETURN jsonb_build_object('ok', true, 'items', v_n);
END $function$;

-- Realtime (opsional, sama seperti tabel outbound lain)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='outbound_items') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.outbound_items;
  END IF;
END $$;
