-- ============================================================
-- MIGRASI v2.0.13 — Perbaikan temuan sinkronisasi WMS <-> Scan WMS
-- Jalankan SEKALI di Supabase SQL Editor SETELAH semua migrasi sebelumnya
-- (aman dijalankan ulang). BACKUP DULU.
-- Isi:
--   K2  kolom whs (outbound_docs, suppliers."Whs") + wms_outbound_create 5 parameter
--   T1  fefo_allocate boleh dipanggil picker
--   T2  wms_outbound_complete: tolak DO kosong / pesanan belum terpenuhi (admin/supervisor boleh paksa)
--   T4  wms_inbound_receive_line: cek kapasitas bila langsung ke rak (selain GR-STAGING) + batas PL
--   T5  wms_rack_add: validasi format kode rak + hapus versi lama 2 parameter (tanpa validasi)
--   T7  wms_opname_post: selisih dihitung terhadap stok saat posting
--   T8  unique (doc,sku,batch) + wms_next_batch_seq di server
--   R4  wms_pick: tolak batch kedaluwarsa
-- ============================================================

-- ---------- K2: kolom whs ----------
ALTER TABLE public.outbound_docs ADD COLUMN IF NOT EXISTS whs varchar;
ALTER TABLE public.suppliers     ADD COLUMN IF NOT EXISTS "Whs" varchar;

DROP FUNCTION IF EXISTS public.wms_outbound_create(text,text,text,text);
CREATE OR REPLACE FUNCTION public.wms_outbound_create(p_no text, p_customer text, p_phone text, p_address text, p_whs text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('picker','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  INSERT INTO outbound_docs(no, customer_name, customer_phone, customer_address, whs)
    VALUES (p_no, trim(p_customer), p_phone, p_address, nullif(trim(coalesce(p_whs,'')),''));
  PERFORM wms_log('OUT_CREATE', p_no, jsonb_build_object('customer',trim(p_customer),'whs',nullif(trim(coalesce(p_whs,'')),'')));
  RETURN jsonb_build_object('ok', true, 'no', p_no);
END $function$;

-- ---------- T1: picker boleh membuat picking list FEFO ----------
CREATE OR REPLACE FUNCTION public.fefo_allocate(p_doc text, p_sku text, p_qty integer)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE need int := p_qty; r record; take int; n int;
BEGIN
  IF auth.uid() IS NOT NULL AND coalesce(wms_role(),'') NOT IN ('picker','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'Jumlah harus lebih dari 0'; END IF;
  IF NOT EXISTS (SELECT 1 FROM outbound_docs WHERE no = p_doc AND status = 'open') THEN RAISE EXCEPTION 'Outbound tidak ditemukan atau sudah selesai'; END IF;
  SELECT coalesce(max(seq),0) INTO n FROM outbound_picks WHERE doc_no = p_doc;
  FOR r IN
    SELECT s.batch, s.expiry, s.rack_code,
      s.qty - wms_held(s.sku,s.batch,s.rack_code)
            - coalesce((SELECT sum(k.qty - k.picked) FROM outbound_picks k JOIN outbound_docs d ON d.no = k.doc_no
                        WHERE d.status='open' AND k.sku=s.sku AND k.batch=s.batch AND k.rack_code=s.rack_code),0) AS avail
    FROM stock s WHERE s.sku = p_sku AND s.rack_code <> 'GR-STAGING' AND s.qty > 0 AND s.expiry >= wms_today()
    ORDER BY s.expiry, s.batch, s.rack_code FOR UPDATE OF s
  LOOP
    EXIT WHEN need <= 0;
    CONTINUE WHEN r.avail <= 0;
    take := least(need, r.avail); n := n + 1;
    INSERT INTO outbound_picks(doc_no,seq,sku,batch,expiry,rack_code,qty) VALUES (p_doc,n,p_sku,r.batch,r.expiry,r.rack_code,take);
    need := need - take;
  END LOOP;
  PERFORM wms_log('FEFO_ALLOCATE', p_doc, jsonb_build_object('sku',p_sku,'qty',p_qty,'sisa',need));
  RETURN need;
END $function$;

-- ---------- R4: wms_pick menolak batch kedaluwarsa ----------
CREATE OR REPLACE FUNCTION public.wms_pick(p_doc text, p_sku text, p_batch text, p_rack text, p_qty integer, p_scanned_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_key text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_status text; k record;
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('picker','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'Jumlah harus lebih dari 0'; END IF;
  p_sku := upper(trim(p_sku)); p_batch := upper(trim(p_batch)); p_rack := upper(trim(p_rack));
  SELECT status INTO v_status FROM outbound_docs WHERE no = p_doc FOR UPDATE;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Dokumen outbound tidak ditemukan'; END IF;
  IF v_status <> 'open' THEN RAISE EXCEPTION 'Dokumen sudah selesai'; END IF;
  SELECT id, qty, picked, expiry INTO k FROM outbound_picks
   WHERE doc_no = p_doc AND sku = p_sku AND batch = p_batch AND rack_code = p_rack AND picked < qty
   ORDER BY seq LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Item tidak ada di picking list (SKU/batch/rak tidak sesuai)'; END IF;
  IF k.expiry < wms_today() THEN RAISE EXCEPTION 'Batch % sudah kedaluwarsa (ED %), tidak boleh dikirim. Hubungi supervisor.', p_batch, k.expiry; END IF;
  IF p_qty > k.qty - k.picked THEN RAISE EXCEPTION 'Melebihi sisa pick (% ctn)', k.qty - k.picked; END IF;
  INSERT INTO stock_movements(type,doc_no,sku,batch,expiry,from_rack,qty,user_id,scanned_at,idempotency_key)
    VALUES ('GI',p_doc,p_sku,p_batch,k.expiry,p_rack,p_qty,auth.uid(),p_scanned_at,p_key) ON CONFLICT (idempotency_key) DO NOTHING;
  IF NOT FOUND THEN RETURN jsonb_build_object('duplicate', true); END IF;
  UPDATE stock SET qty = qty - p_qty, updated_at = now() WHERE sku = p_sku AND batch = p_batch AND rack_code = p_rack AND qty >= p_qty;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stok % | % di rak % tidak cukup', p_sku, p_batch, p_rack; END IF;
  UPDATE outbound_picks SET picked = picked + p_qty WHERE id = k.id;
  PERFORM wms_log('GI_PICK', p_doc, jsonb_build_object('sku',p_sku,'batch',p_batch,'rack',p_rack,'qty',p_qty));
  RETURN jsonb_build_object('ok', true);
END $function$;

-- ---------- T2: penyelesaian outbound memeriksa pesanan ----------
-- p_allow_short = true hanya berlaku untuk admin/supervisor (kirim sebagian).
DROP FUNCTION IF EXISTS public.wms_outbound_complete(text);
CREATE OR REPLACE FUNCTION public.wms_outbound_complete(p_doc text, p_allow_short boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_updated boolean; v_role text := wms_role(); v_req int; v_picked int; v_short boolean;
BEGIN
  IF coalesce(v_role,'') NOT IN ('picker','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF NOT EXISTS (SELECT 1 FROM outbound_docs WHERE no = p_doc) THEN RAISE EXCEPTION 'Dokumen outbound tidak ditemukan'; END IF;
  IF NOT EXISTS (SELECT 1 FROM outbound_picks WHERE doc_no = p_doc) THEN
    RAISE EXCEPTION 'Picking list masih kosong (belum ada barang yang dialokasikan)';
  END IF;
  IF EXISTS (SELECT 1 FROM outbound_picks WHERE doc_no = p_doc AND picked < qty) THEN RAISE EXCEPTION 'Picking belum lengkap'; END IF;

  SELECT coalesce(sum(qty),0) INTO v_req FROM outbound_items WHERE doc_no = p_doc;
  SELECT coalesce(sum(picked),0) INTO v_picked FROM outbound_picks WHERE doc_no = p_doc;
  SELECT EXISTS (SELECT 1 FROM outbound_items i WHERE i.doc_no = p_doc
                 AND i.qty > coalesce((SELECT sum(k.picked) FROM outbound_picks k WHERE k.doc_no = i.doc_no AND k.sku = i.sku),0))
    INTO v_short;
  IF v_short AND NOT (coalesce(p_allow_short,false) AND v_role IN ('admin','supervisor')) THEN
    RAISE EXCEPTION 'Pesanan belum terpenuhi penuh (diminta % ctn, terambil % ctn). Alokasikan sisa setelah stok tersedia, atau minta admin/supervisor menyelesaikan sebagian dari WMS.', v_req, v_picked;
  END IF;

  UPDATE outbound_docs SET status='done', completed_at=now(), completed_by=auth.uid() WHERE no = p_doc AND status = 'open';
  v_updated := FOUND;
  IF v_updated THEN PERFORM wms_log('OUT_COMPLETE', p_doc, jsonb_build_object('diminta',v_req,'terambil',v_picked,'sebagian',v_short)); END IF;
  RETURN jsonb_build_object('ok', true, 'updated', v_updated, 'short', v_short);
END $function$;
REVOKE EXECUTE ON FUNCTION public.wms_outbound_complete(text,boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.wms_outbound_complete(text,boolean) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.wms_outbound_create(text,text,text,text,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.wms_outbound_create(text,text,text,text,text) TO authenticated;

-- ---------- T4: terima barang — batas PL + kapasitas rak bila langsung ke rak ----------
CREATE OR REPLACE FUNCTION public.wms_inbound_receive_line(p_doc text, p_sku text, p_batch text, p_qty integer, p_rack text DEFAULT NULL::text, p_scanned_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_key text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_status text; v_exp date; v_prod date; v_gr text; v_pl integer; v_rcv integer; v_cap integer; v_used integer;
  v_sku text := upper(trim(p_sku)); v_batch text := upper(trim(p_batch));
  v_rack text := coalesce(nullif(upper(trim(coalesce(p_rack,''))),''),'GR-STAGING');
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'Jumlah harus lebih dari 0'; END IF;
  SELECT status INTO v_status FROM inbound_docs WHERE no = p_doc FOR UPDATE;
  IF v_status IS NULL THEN RAISE EXCEPTION 'Dokumen inbound tidak ditemukan'; END IF;
  IF v_status <> 'open' THEN RAISE EXCEPTION 'Dokumen sudah selesai'; END IF;
  SELECT capacity INTO v_cap FROM racks WHERE code = v_rack AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Rak % tidak terdaftar atau nonaktif', v_rack; END IF;
  SELECT expiry, production_date, gr_no, qty_pl, qty_received INTO v_exp, v_prod, v_gr, v_pl, v_rcv FROM inbound_lines
    WHERE doc_no = p_doc AND sku = v_sku AND batch = v_batch FOR UPDATE;
  IF v_exp IS NULL THEN RAISE EXCEPTION 'Baris item tidak ditemukan di dokumen ini (tidak ada di Packing List)'; END IF;

  INSERT INTO stock_movements(type,doc_no,sku,batch,expiry,to_rack,qty,user_id,scanned_at,idempotency_key,gr_no)
    VALUES ('GR',p_doc,v_sku,v_batch,v_exp,v_rack,p_qty,auth.uid(),p_scanned_at,p_key,v_gr)
    ON CONFLICT (idempotency_key) DO NOTHING;
  IF NOT FOUND THEN RETURN jsonb_build_object('duplicate', true); END IF;

  -- RAISE membatalkan seluruh transaksi (termasuk stock_movements di atas)
  IF v_rcv + p_qty > v_pl THEN
    RAISE EXCEPTION 'Jumlah diterima melebihi Jumlah PL (PL %, sudah diterima %, sisa %)', v_pl, v_rcv, greatest(v_pl - v_rcv, 0);
  END IF;
  IF v_rack <> 'GR-STAGING' AND coalesce(v_cap,0) > 0 THEN
    SELECT coalesce(sum(qty),0) INTO v_used FROM stock WHERE rack_code = v_rack;
    IF v_used + p_qty > v_cap THEN
      RAISE EXCEPTION 'Kapasitas rak % tidak cukup (sisa % ctn). Terima ke GR-STAGING lalu Putaway.', v_rack, greatest(v_cap - v_used, 0);
    END IF;
  END IF;

  UPDATE inbound_lines SET qty_received = qty_received + p_qty, rack_code = v_rack, pic = auth.uid()
    WHERE doc_no = p_doc AND sku = v_sku AND batch = v_batch;
  INSERT INTO stock(sku,batch,expiry,production_date,rack_code,qty)
    VALUES (v_sku,v_batch,v_exp,v_prod,v_rack,p_qty)
    ON CONFLICT (sku,batch,rack_code) DO UPDATE SET qty = stock.qty + EXCLUDED.qty,
      expiry = EXCLUDED.expiry, production_date = EXCLUDED.production_date, updated_at = now();
  PERFORM wms_log('GR_RECEIVE', p_doc, jsonb_build_object('sku',v_sku,'batch',v_batch,'qty',p_qty,'rack',v_rack));
  RETURN jsonb_build_object('ok', true);
END $function$;

-- ---------- T5: validasi format kode rak (zona-bim-level), selaras dengan aplikasi scan ----------
-- Versi lama 2 parameter (dari functions.sql) tidak punya validasi dan akan tetap menjawab panggilan 2 argumen bila tidak dihapus.
DROP FUNCTION IF EXISTS public.wms_rack_add(text,text);
CREATE OR REPLACE FUNCTION public.wms_rack_add(p_code text, p_zone text, p_capacity integer DEFAULT 0)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_code text := upper(trim(p_code));
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF coalesce(p_capacity,0) < 0 THEN RAISE EXCEPTION 'Kapasitas tidak valid'; END IF;
  IF v_code !~ '^[A-Z]{1,3}-[0-9]{1,3}-[0-9]{1,3}$' AND v_code NOT IN ('GR-STAGING','NON-RACK') THEN
    RAISE EXCEPTION 'Format kode rak harus ZONA-BIM-LEVEL, mis. A-01-03 (zona 1-3 huruf, bim & level angka)';
  END IF;
  INSERT INTO racks(code, zone, capacity) VALUES (v_code, p_zone, coalesce(p_capacity,0));
  PERFORM wms_log('RACK_ADD', null, jsonb_build_object('code',v_code,'zone',p_zone,'capacity',coalesce(p_capacity,0)));
  RETURN jsonb_build_object('ok', true);
END $function$;
REVOKE EXECUTE ON FUNCTION public.wms_rack_add(text,text,integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.wms_rack_add(text,text,integer) TO authenticated;

-- ---------- T7: opname — selisih terhadap stok SAAT POSTING, bukan snapshot ----------
-- Transaksi (terima/pick/putaway) yang terjadi selama opname tetap konsisten dengan buku besar.
-- Baris yang stok-nya sudah habis (baris dihapus) tetap bisa diisi bila batch pernah tercatat.
CREATE OR REPLACE FUNCTION public.wms_opname_post(p_doc text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r record; v_sku text; d int; n int := 0; v_cur int; v_exp date; v_prod date;
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  SELECT sku INTO v_sku FROM opname_docs WHERE no = p_doc AND status = 'open' FOR UPDATE;
  IF v_sku IS NULL THEN RAISE EXCEPTION 'Sesi opname tidak ditemukan atau sudah selesai'; END IF;
  FOR r IN SELECT * FROM opname_lines WHERE doc_no = p_doc AND qty_physical IS NOT NULL LOOP
    v_cur := NULL;
    SELECT qty INTO v_cur FROM stock WHERE sku = v_sku AND batch = r.batch AND rack_code = r.rack_code FOR UPDATE;
    IF v_cur IS NULL THEN
      IF r.qty_physical <= 0 THEN CONTINUE; END IF;
      SELECT m.expiry INTO v_exp FROM stock_movements m WHERE m.sku = v_sku AND m.batch = r.batch AND m.expiry IS NOT NULL ORDER BY m.moved_at DESC LIMIT 1;
      IF v_exp IS NULL THEN CONTINUE; END IF;
      SELECT production_date INTO v_prod FROM packing_list_lines WHERE sku = v_sku AND batch = r.batch LIMIT 1;
      INSERT INTO stock(sku,batch,expiry,production_date,rack_code,qty) VALUES (v_sku,r.batch,v_exp,v_prod,r.rack_code,r.qty_physical);
      v_cur := 0;
      d := r.qty_physical;
    ELSE
      d := r.qty_physical - v_cur;
      IF d <> 0 THEN UPDATE stock SET qty = r.qty_physical, updated_at = now() WHERE sku = v_sku AND batch = r.batch AND rack_code = r.rack_code; END IF;
    END IF;
    IF d <> 0 THEN
      n := n + 1;
      INSERT INTO stock_movements(type,doc_no,sku,batch,to_rack,qty,user_id,reason)
        VALUES ('ADJ',p_doc,v_sku,r.batch,r.rack_code,d,auth.uid(),'Stok Opname '||p_doc||' (sistem '||v_cur||', fisik '||r.qty_physical||')');
    END IF;
  END LOOP;
  DELETE FROM stock WHERE sku = v_sku AND qty <= 0;
  UPDATE opname_docs SET status='done', completed_at=now(), completed_by=auth.uid() WHERE no = p_doc;
  PERFORM wms_log('OPNAME_POST', p_doc, jsonb_build_object('sku',v_sku,'baris_selisih',n));
  RETURN jsonb_build_object('ok', true, 'selisih', n);
END $function$;
REVOKE EXECUTE ON FUNCTION public.wms_opname_post(text) FROM PUBLIC, anon;

-- ---------- T8: integritas baris + penomoran batch di server ----------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.inbound_lines GROUP BY doc_no, sku, batch HAVING count(*) > 1) THEN
    RAISE WARNING 'LEWATI unique inbound_lines: ada baris ganda (doc_no,sku,batch). Bersihkan dulu: SELECT doc_no,sku,batch,count(*) FROM inbound_lines GROUP BY 1,2,3 HAVING count(*)>1;';
  ELSE
    CREATE UNIQUE INDEX IF NOT EXISTS ux_inbound_lines_doc_sku_batch ON public.inbound_lines(doc_no, sku, batch);
  END IF;
  IF EXISTS (SELECT 1 FROM public.packing_list_lines GROUP BY pl_no, sku, batch HAVING count(*) > 1) THEN
    RAISE WARNING 'LEWATI unique packing_list_lines: ada baris ganda (pl_no,sku,batch). Bersihkan dulu: SELECT pl_no,sku,batch,count(*) FROM packing_list_lines GROUP BY 1,2,3 HAVING count(*)>1;';
  ELSE
    CREATE UNIQUE INDEX IF NOT EXISTS ux_pl_lines_pl_sku_batch ON public.packing_list_lines(pl_no, sku, batch);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.wms_pl_add_line(p_pl text, p_sku text, p_batch text, p_production date, p_expiry date, p_qty integer, p_gr text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_sku text := upper(trim(p_sku)); v_batch text := upper(trim(p_batch));
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'Jumlah harus lebih dari 0'; END IF;
  IF NOT EXISTS (SELECT 1 FROM packing_lists WHERE no=p_pl AND status='open') THEN RAISE EXCEPTION 'Packing List tidak ditemukan atau sudah dipakai'; END IF;
  IF NOT EXISTS (SELECT 1 FROM products WHERE sku=v_sku AND active) THEN RAISE EXCEPTION 'SKU % belum terdaftar di master produk', v_sku; END IF;
  IF EXISTS (SELECT 1 FROM packing_list_lines WHERE pl_no=p_pl AND sku=v_sku AND batch=v_batch) THEN
    RAISE EXCEPTION 'Baris SKU % dengan batch % sudah ada di Packing List ini', v_sku, v_batch;
  END IF;
  INSERT INTO packing_list_lines(pl_no, sku, batch, production_date, expiry, qty, gr_no)
    VALUES (p_pl, v_sku, v_batch, p_production, p_expiry, p_qty, nullif(upper(trim(coalesce(p_gr,''))),''));
  PERFORM wms_log('PL_ADD_LINE', p_pl, jsonb_build_object('sku',v_sku,'batch',v_batch,'qty',p_qty,'gr_no',nullif(upper(trim(coalesce(p_gr,''))),'')));
  RETURN jsonb_build_object('ok', true);
END $function$;

-- Nomor urut batch berikutnya untuk SKU + ED (yyyymmdd): melihat Packing List (termasuk yang masih open),
-- inbound, stok, dan riwayat — sehingga dua pengguna bersamaan / batch lama yang sudah habis tidak bertabrakan.
CREATE OR REPLACE FUNCTION public.wms_next_batch_seq(p_sku text, p_ymd text)
 RETURNS integer LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_sku text := upper(trim(p_sku)); v_max int;
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF p_ymd IS NULL OR p_ymd !~ '^[0-9]{8}$' THEN RAISE EXCEPTION 'Format tanggal batch harus YYYYMMDD'; END IF;
  SELECT coalesce(max((substring(b from '\.([0-9]+)$'))::int), 0) INTO v_max FROM (
    SELECT batch AS b FROM packing_list_lines WHERE sku = v_sku AND batch LIKE p_ymd || '.%'
    UNION ALL SELECT batch FROM inbound_lines     WHERE sku = v_sku AND batch LIKE p_ymd || '.%'
    UNION ALL SELECT batch FROM stock             WHERE sku = v_sku AND batch LIKE p_ymd || '.%'
    UNION ALL SELECT batch FROM stock_movements   WHERE sku = v_sku AND batch LIKE p_ymd || '.%'
  ) x WHERE b ~ '\.[0-9]+$';
  RETURN v_max + 1;
END $function$;
REVOKE EXECUTE ON FUNCTION public.wms_next_batch_seq(text,text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.wms_next_batch_seq(text,text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ---------- Cek hasil (tampil di tabel hasil SQL Editor; hanya membaca) ----------
-- Semua baris harus berstatus OK. 'GANDA' = masih ada versi lama dengan argumen berbeda (hapus dengan DROP FUNCTION).
-- 'BELUM ADA' = unique index dilewati karena ada baris ganda: bersihkan dulu (query ada di pesan WARNING), lalu jalankan ulang file ini.
SELECT 'fungsi ' || v.n AS cek, count(p.oid)::text AS jumlah_versi,
       CASE WHEN count(p.oid) = 1 THEN 'OK' WHEN count(p.oid) = 0 THEN 'TIDAK ADA' ELSE 'GANDA - hapus versi lama' END AS status
FROM (VALUES ('wms_outbound_complete'),('wms_outbound_create'),('wms_next_batch_seq'),('wms_rack_add'),('fefo_allocate'),
             ('wms_pick'),('wms_inbound_receive_line'),('wms_opname_post'),('wms_pl_add_line')) v(n)
LEFT JOIN pg_proc p ON p.proname = v.n AND p.pronamespace = 'public'::regnamespace
GROUP BY v.n
UNION ALL
SELECT 'index ' || v.n, '',
       CASE WHEN EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='public' AND indexname = v.n) THEN 'OK'
            ELSE 'BELUM ADA - ada data ganda, bersihkan lalu jalankan ulang' END
FROM (VALUES ('ux_inbound_lines_doc_sku_batch'),('ux_pl_lines_pl_sku_batch')) v(n)
ORDER BY 1;
