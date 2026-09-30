-- Migrasi: No GR SAP + format batch baru (YYYYMMDD.NNN)
-- Jalankan SEKALI di Supabase SQL Editor. Backup dulu.
begin;

-- 1) Kolom No GR (untuk tracking di sistem, tidak dicetak di label)
alter table public.packing_list_lines add column if not exists gr_no varchar;
alter table public.inbound_lines      add column if not exists gr_no varchar;
alter table public.stock_movements    add column if not exists gr_no varchar;

-- 2) Fungsi backend yang membawa gr_no dari Packing List -> Inbound -> Riwayat GR
DROP FUNCTION IF EXISTS public.wms_pl_add_line(text,text,text,date,date,integer);
CREATE OR REPLACE FUNCTION public.wms_pl_add_line(p_pl text, p_sku text, p_batch text, p_production date, p_expiry date, p_qty integer, p_gr text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'Jumlah harus lebih dari 0'; END IF;
  IF NOT EXISTS (SELECT 1 FROM packing_lists WHERE no=p_pl AND status='open') THEN RAISE EXCEPTION 'Packing List tidak ditemukan atau sudah dipakai'; END IF;
  IF NOT EXISTS (SELECT 1 FROM products WHERE sku=upper(trim(p_sku)) AND active) THEN RAISE EXCEPTION 'SKU % belum terdaftar di master produk', upper(trim(p_sku)); END IF;
  INSERT INTO packing_list_lines(pl_no, sku, batch, production_date, expiry, qty, gr_no)
    VALUES (p_pl, upper(trim(p_sku)), upper(trim(p_batch)), p_production, p_expiry, p_qty, nullif(upper(trim(coalesce(p_gr,''))),''));
  PERFORM wms_log('PL_ADD_LINE', p_pl, jsonb_build_object('sku',upper(trim(p_sku)),'batch',upper(trim(p_batch)),'qty',p_qty,'gr_no',nullif(upper(trim(coalesce(p_gr,''))),'')));
  RETURN jsonb_build_object('ok', true);
END $function$;

CREATE OR REPLACE FUNCTION public.wms_inbound_create(p_no text, p_pl text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r record; v_supplier text;
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  SELECT supplier INTO v_supplier FROM packing_lists WHERE no = p_pl AND status = 'open';
  IF v_supplier IS NULL THEN RAISE EXCEPTION 'Packing List tidak ditemukan atau sudah dipakai'; END IF;
  INSERT INTO inbound_docs(no, packing_list, supplier) VALUES (p_no, p_pl, v_supplier);
  FOR r IN SELECT * FROM packing_list_lines WHERE pl_no = p_pl LOOP
    INSERT INTO inbound_lines(doc_no, sku, batch, expiry, production_date, qty_pl, qty_received, gr_no)
      VALUES (p_no, r.sku, r.batch, r.expiry, r.production_date, r.qty, 0, r.gr_no);
  END LOOP;
  UPDATE packing_lists SET status='used' WHERE no = p_pl;
  PERFORM wms_log('IN_CREATE', p_no, jsonb_build_object('packing_list',p_pl,'supplier',v_supplier));
  RETURN jsonb_build_object('ok', true, 'no', p_no);
END $function$;

CREATE OR REPLACE FUNCTION public.wms_inbound_receive_line(p_doc text, p_sku text, p_batch text, p_qty integer, p_rack text DEFAULT NULL::text, p_scanned_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_key text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_status text; v_exp date; v_prod date; v_gr text; v_rack text := coalesce(nullif(upper(trim(coalesce(p_rack,''))),''),'GR-STAGING');
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'Jumlah harus lebih dari 0'; END IF;
  SELECT status INTO v_status FROM inbound_docs WHERE no = p_doc FOR UPDATE;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Dokumen inbound tidak ditemukan'; END IF;
  IF v_status <> 'open' THEN RAISE EXCEPTION 'Dokumen sudah selesai'; END IF;
  IF NOT EXISTS (SELECT 1 FROM racks WHERE code = v_rack AND active) THEN RAISE EXCEPTION 'Rak % tidak terdaftar atau nonaktif', v_rack; END IF;
  SELECT expiry, production_date, gr_no INTO v_exp, v_prod, v_gr FROM inbound_lines
    WHERE doc_no = p_doc AND sku = upper(trim(p_sku)) AND batch = upper(trim(p_batch));
  IF v_exp IS NULL THEN RAISE EXCEPTION 'Baris item tidak ditemukan di dokumen ini (tidak ada di Packing List)'; END IF;

  INSERT INTO stock_movements(type,doc_no,sku,batch,expiry,to_rack,qty,user_id,scanned_at,idempotency_key,gr_no)
    VALUES ('GR',p_doc,upper(trim(p_sku)),upper(trim(p_batch)),v_exp,v_rack,p_qty,auth.uid(),p_scanned_at,p_key,v_gr)
    ON CONFLICT (idempotency_key) DO NOTHING;
  IF NOT FOUND THEN RETURN jsonb_build_object('duplicate', true); END IF;

  UPDATE inbound_lines SET qty_received = qty_received + p_qty, rack_code = v_rack, pic = auth.uid()
    WHERE doc_no = p_doc AND sku = upper(trim(p_sku)) AND batch = upper(trim(p_batch));
  INSERT INTO stock(sku,batch,expiry,production_date,rack_code,qty)
    VALUES (upper(trim(p_sku)),upper(trim(p_batch)),v_exp,v_prod,v_rack,p_qty)
    ON CONFLICT (sku,batch,rack_code) DO UPDATE SET qty = stock.qty + EXCLUDED.qty,
      expiry = EXCLUDED.expiry, production_date = EXCLUDED.production_date, updated_at = now();
  PERFORM wms_log('GR_RECEIVE', p_doc, jsonb_build_object('sku',upper(trim(p_sku)),'batch',upper(trim(p_batch)),'qty',p_qty,'rack',v_rack));
  RETURN jsonb_build_object('ok', true);
END $function$;

-- 3) (Opsional, hanya jika sudah ada data lama) ubah batch lama
--    PREFIX.001.DDMMYYYY.001  ->  YYYYMMDD.001      contoh: FGKGPA.001.10032028.001 -> 20280310.001
--    Batch yang tidak cocok pola lama dibiarkan. Label QR yang sudah tercetak dengan batch lama tidak cocok lagi.
create or replace function pg_temp.fix_batch(b text) returns text language sql immutable as $$
  select case
    when b ~ '^.*\.(0[1-9]|[12][0-9]|3[01])(0[1-9]|1[0-2])(20[0-9]{2}|21[0-9]{2})\.[0-9]{3}$'
    then regexp_replace(b, '^.*\.(\d{2})(\d{2})(\d{4})\.(\d{3})$', '\3\2\1.\4')
    else b end
$$;
update public.stock              set batch = pg_temp.fix_batch(batch) where batch <> pg_temp.fix_batch(batch);
update public.packing_list_lines set batch = pg_temp.fix_batch(batch) where batch <> pg_temp.fix_batch(batch);
update public.inbound_lines      set batch = pg_temp.fix_batch(batch) where batch <> pg_temp.fix_batch(batch);
update public.outbound_picks     set batch = pg_temp.fix_batch(batch) where batch <> pg_temp.fix_batch(batch);
update public.opname_lines       set batch = pg_temp.fix_batch(batch) where batch <> pg_temp.fix_batch(batch);
update public.stock_movements    set batch = pg_temp.fix_batch(batch) where batch <> pg_temp.fix_batch(batch);

commit;
