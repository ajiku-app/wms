-- v2.0.11 — Jumlah diterima tidak boleh melebihi Jumlah PL (kurang boleh, lebih tidak).
-- Jalankan sekali di SQL Editor Supabase. Berlaku juga untuk scan dari HP karena dicek di server.
CREATE OR REPLACE FUNCTION public.wms_inbound_receive_line(p_doc text, p_sku text, p_batch text, p_qty integer, p_rack text DEFAULT NULL::text, p_scanned_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_key text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_status text; v_exp date; v_prod date; v_gr text; v_pl integer; v_rcv integer; v_rack text := coalesce(nullif(upper(trim(coalesce(p_rack,''))),''),'GR-STAGING');
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'Jumlah harus lebih dari 0'; END IF;
  SELECT status INTO v_status FROM inbound_docs WHERE no = p_doc FOR UPDATE;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Dokumen inbound tidak ditemukan'; END IF;
  IF v_status <> 'open' THEN RAISE EXCEPTION 'Dokumen sudah selesai'; END IF;
  IF NOT EXISTS (SELECT 1 FROM racks WHERE code = v_rack AND active) THEN RAISE EXCEPTION 'Rak % tidak terdaftar atau nonaktif', v_rack; END IF;
  SELECT expiry, production_date, gr_no, qty_pl, qty_received INTO v_exp, v_prod, v_gr, v_pl, v_rcv FROM inbound_lines
    WHERE doc_no = p_doc AND sku = upper(trim(p_sku)) AND batch = upper(trim(p_batch)) FOR UPDATE;
  IF v_exp IS NULL THEN RAISE EXCEPTION 'Baris item tidak ditemukan di dokumen ini (tidak ada di Packing List)'; END IF;

  INSERT INTO stock_movements(type,doc_no,sku,batch,expiry,to_rack,qty,user_id,scanned_at,idempotency_key,gr_no)
    VALUES ('GR',p_doc,upper(trim(p_sku)),upper(trim(p_batch)),v_exp,v_rack,p_qty,auth.uid(),p_scanned_at,p_key,v_gr)
    ON CONFLICT (idempotency_key) DO NOTHING;
  IF NOT FOUND THEN RETURN jsonb_build_object('duplicate', true); END IF;

  -- dicek setelah pengecekan duplikat; RAISE membatalkan seluruh transaksi (termasuk stock_movements di atas)
  IF v_rcv + p_qty > v_pl THEN
    RAISE EXCEPTION 'Jumlah diterima melebihi Jumlah PL (PL %, sudah diterima %, sisa %)', v_pl, v_rcv, greatest(v_pl - v_rcv, 0);
  END IF;

  UPDATE inbound_lines SET qty_received = qty_received + p_qty, rack_code = v_rack, pic = auth.uid()
    WHERE doc_no = p_doc AND sku = upper(trim(p_sku)) AND batch = upper(trim(p_batch));
  INSERT INTO stock(sku,batch,expiry,production_date,rack_code,qty)
    VALUES (upper(trim(p_sku)),upper(trim(p_batch)),v_exp,v_prod,v_rack,p_qty)
    ON CONFLICT (sku,batch,rack_code) DO UPDATE SET qty = stock.qty + EXCLUDED.qty,
      expiry = EXCLUDED.expiry, production_date = EXCLUDED.production_date, updated_at = now();
  PERFORM wms_log('GR_RECEIVE', p_doc, jsonb_build_object('sku',upper(trim(p_sku)),'batch',upper(trim(p_batch)),'qty',p_qty,'rack',v_rack));
  RETURN jsonb_build_object('ok', true);
END $function$;

-- Cek data lama yang sudah terlanjur melebihi PL (hanya membaca, tidak mengubah apa pun):
-- SELECT doc_no, sku, batch, qty_pl, qty_received FROM inbound_lines WHERE qty_received > qty_pl;
