-- Migrasi: Edit & Hapus Packing List
-- Jalankan SEKALI di Supabase SQL Editor (aman dijalankan ulang).
-- Hanya Packing List berstatus 'open' (Menunggu) yang bisa diubah / dihapus.

CREATE OR REPLACE FUNCTION public.wms_pl_update(p_no text, p_supplier text, p_doc_date date, p_gr text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_gr text := nullif(upper(trim(coalesce(p_gr,''))),'');
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF p_supplier IS NULL OR trim(p_supplier) = '' THEN RAISE EXCEPTION 'Pemasok wajib diisi'; END IF;
  IF NOT EXISTS (SELECT 1 FROM packing_lists WHERE no = p_no AND status = 'open') THEN
    RAISE EXCEPTION 'Packing List tidak ditemukan atau sudah dipakai';
  END IF;
  UPDATE packing_lists SET supplier = trim(p_supplier), doc_date = p_doc_date WHERE no = p_no;
  -- No GR diisi -> diterapkan ke semua baris Packing List ini; kosong -> GR per baris tidak diubah
  IF v_gr IS NOT NULL THEN UPDATE packing_list_lines SET gr_no = v_gr WHERE pl_no = p_no; END IF;
  PERFORM wms_log('PL_UPDATE', p_no, jsonb_build_object('supplier',trim(p_supplier),'doc_date',p_doc_date,'gr_no',v_gr));
  RETURN jsonb_build_object('ok', true);
END $function$;

CREATE OR REPLACE FUNCTION public.wms_pl_delete(p_no text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_n integer;
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF NOT EXISTS (SELECT 1 FROM packing_lists WHERE no = p_no AND status = 'open') THEN
    RAISE EXCEPTION 'Packing List tidak ditemukan atau sudah dipakai (tidak bisa dihapus)';
  END IF;
  DELETE FROM packing_list_lines WHERE pl_no = p_no;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  DELETE FROM packing_lists WHERE no = p_no;
  PERFORM wms_log('PL_DELETE', p_no, jsonb_build_object('lines_deleted', v_n));
  RETURN jsonb_build_object('ok', true);
END $function$;
