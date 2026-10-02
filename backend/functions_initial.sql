-- ############################################################
-- functions_initial.sql — HANYA UNTUK BOOTSTRAP DATABASE BARU (langkah 3 urutan instalasi).
-- Ini snapshot AWAL (29 Sep 2026) dan USANG. JANGAN dijalankan di database yang sudah berjalan.
-- Sumber kebenaran fungsi sekarang: backend/functions.sql (konsolidasi v2.0.17 + v2.0.18).
-- ############################################################
-- ############################################################
-- PERHATIAN (v2.0.13): file ini adalah SNAPSHOT AWAL (29 Sep 2026).
-- Fungsi berikut sudah DIGANTI oleh migrasi dan versi di bawah ini USANG:
--   wms_inbound_receive_line, wms_move, fefo_allocate, wms_pick,
--   wms_outbound_create, wms_outbound_complete, wms_rack_add,
--   wms_opname_post, wms_pl_add_line
-- Untuk database BARU: jalankan file ini, lalu SEMUA migrasi sesuai
-- urutan di backend/README.md (berakhir di migrate_v2_0_13_sinkron.sql).
-- JANGAN menjalankan ulang file ini di database yang sudah berjalan.
-- ############################################################

-- ============================================================
-- BACKEND — FUNGSI (API sesungguhnya aplikasi ini)
-- Semua ditulis SECURITY DEFINER: berjalan dengan hak akses
-- pemilik fungsi, TAPI setiap fungsi mengecek wms_role() di baris
-- pertama dan menolak (RAISE EXCEPTION) jika peran tidak sesuai.
-- Frontend memanggil ini lewat endpoint REST bawaan Supabase:
--   POST /rest/v1/rpc/<nama_fungsi>   body: {"p_xxx": ...}
-- Lihat API.md untuk kontrak lengkap tiap endpoint.
-- Disalin dari definisi yang BENAR-BENAR aktif di database pada
-- 29 September 2026, termasuk fitur activity_log yang ditambahkan
-- otomatis oleh proses pengerasan keamanan Supabase.
-- ============================================================

-- Peran pengguna yang sedang login (null jika belum diberi role / nonaktif)
CREATE OR REPLACE FUNCTION public.wms_role()
 RETURNS text
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$ SELECT role FROM profiles WHERE id = auth.uid() AND active $function$;

-- Dipanggil otomatis oleh trigger saat akun baru mendaftar (auth.users)
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO profiles(id, name) VALUES (new.id, split_part(new.email,'@',1)) ON CONFLICT DO NOTHING;
  RETURN new;
END $function$;

-- ---- Activity log (audit trail) ----

-- Dipanggil dari dalam fungsi aksi lain untuk mencatat satu baris log.
CREATE OR REPLACE FUNCTION public.wms_log(p_action text, p_doc text DEFAULT NULL::text, p_detail jsonb DEFAULT '{}'::jsonb)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO activity_log(user_id,user_name,user_role,action,doc_no,detail)
  SELECT auth.uid(), pr.name, pr.role, p_action, p_doc, coalesce(p_detail,'{}'::jsonb)
  FROM profiles pr WHERE pr.id = auth.uid();
END $function$;

-- Trigger di auth.users: mencatat setiap kali seseorang berhasil login.
CREATE OR REPLACE FUNCTION public.wms_log_login()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.last_sign_in_at IS DISTINCT FROM OLD.last_sign_in_at THEN
    INSERT INTO activity_log(user_id,user_name,user_role,action)
    SELECT NEW.id, pr.name, pr.role, 'LOGIN' FROM profiles pr WHERE pr.id = NEW.id;
  END IF;
  RETURN NEW;
END $function$;

-- Satu-satunya jalan MEMBACA activity_log (tabelnya sendiri tertutup total).
-- Admin/supervisor melihat semua baris; role lain hanya melihat baris miliknya sendiri.
CREATE OR REPLACE FUNCTION public.wms_get_activity_log(p_limit integer DEFAULT 100, p_before timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_role text := wms_role(); v_uid uuid := auth.uid();
BEGIN
  IF v_role IS NULL THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  RETURN COALESCE((SELECT jsonb_agg(t) FROM (
    SELECT id, created_at, action, doc_no, detail, user_name, user_role
    FROM activity_log
    WHERE (v_role IN ('admin','supervisor') OR user_id = v_uid)
      AND (p_before IS NULL OR created_at < p_before)
    ORDER BY created_at DESC LIMIT LEAST(coalesce(p_limit,100),200)
  ) t), '[]'::jsonb);
END $function$;

-- Admin/supervisor memberi role ke pengguna baru
CREATE OR REPLACE FUNCTION public.wms_set_role(p_user uuid, p_role text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF p_role NOT IN ('inbound','picker','admin','supervisor') THEN RAISE EXCEPTION 'Role tidak valid'; END IF;
  UPDATE profiles SET role = p_role WHERE id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pengguna tidak ditemukan'; END IF;
  PERFORM wms_log('USER_SET_ROLE', NULL, jsonb_build_object('target_user',p_user,'role',p_role));
  RETURN jsonb_build_object('ok', true);
END $function$;

CREATE OR REPLACE FUNCTION public.wms_user_set_active(p_user uuid, p_active boolean)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  UPDATE profiles SET active = p_active WHERE id = p_user;
  PERFORM wms_log('USER_SET_ACTIVE', NULL, jsonb_build_object('target_user',p_user,'active',p_active));
  RETURN jsonb_build_object('ok', true);
END $function$;

-- Master: produk & rak
CREATE OR REPLACE FUNCTION public.wms_product_add(p_sku text, p_name text, p_cpp integer)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF p_cpp IS NULL OR p_cpp <= 0 THEN RAISE EXCEPTION 'Pcs per carton harus lebih dari 0'; END IF;
  INSERT INTO products(sku,name,pcs_per_ctn) VALUES (upper(trim(p_sku)), trim(p_name), p_cpp);
  PERFORM wms_log('PRODUCT_ADD', NULL, jsonb_build_object('sku',upper(trim(p_sku)),'name',trim(p_name)));
  RETURN jsonb_build_object('ok', true);
END $function$;

CREATE OR REPLACE FUNCTION public.wms_rack_add(p_code text, p_zone text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  INSERT INTO racks(code, zone) VALUES (upper(trim(p_code)), p_zone);
  PERFORM wms_log('RACK_ADD', NULL, jsonb_build_object('code',upper(trim(p_code)),'zone',p_zone));
  RETURN jsonb_build_object('ok', true);
END $function$;

CREATE OR REPLACE FUNCTION public.wms_rack_set_active(p_code text, p_active boolean)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  UPDATE racks SET active = p_active WHERE code = upper(trim(p_code));
  PERFORM wms_log('RACK_SET_ACTIVE', NULL, jsonb_build_object('code',upper(trim(p_code)),'active',p_active));
  RETURN jsonb_build_object('ok', true);
END $function$;

-- Master: pemasok & customer
CREATE OR REPLACE FUNCTION public.wms_supplier_add(p_name text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  INSERT INTO suppliers(name) VALUES (trim(p_name));
  PERFORM wms_log('SUPPLIER_ADD', NULL, jsonb_build_object('name',trim(p_name)));
  RETURN jsonb_build_object('ok', true);
END $function$;

CREATE OR REPLACE FUNCTION public.wms_customer_add(p_name text, p_phone text DEFAULT NULL::text, p_address text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('picker','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  INSERT INTO customers(name, phone, address) VALUES (trim(p_name), p_phone, p_address);
  PERFORM wms_log('CUSTOMER_ADD', NULL, jsonb_build_object('name',trim(p_name)));
  RETURN jsonb_build_object('ok', true);
END $function$;

-- Packing List
CREATE OR REPLACE FUNCTION public.wms_pl_create(p_no text, p_supplier text, p_doc_date date DEFAULT CURRENT_DATE)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  INSERT INTO packing_lists(no, supplier, doc_date, created_by) VALUES (p_no, trim(p_supplier), p_doc_date, auth.uid());
  PERFORM wms_log('PL_CREATE', p_no, jsonb_build_object('supplier',trim(p_supplier),'doc_date',p_doc_date));
  RETURN jsonb_build_object('ok', true, 'no', p_no);
END $function$;

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

-- Inbound
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

-- Terima 1 baris inbound. Boleh dipanggil bertahap (per scan): qty_received bertambah (+p_qty),
-- bukan menimpa. idempotency_key mencegah scan ganda tercatat dua kali (dipakai bersama aplikasi scan HP).
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

CREATE OR REPLACE FUNCTION public.wms_inbound_complete(p_doc text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_updated boolean;
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  UPDATE inbound_docs SET status='done', completed_at=now(), completed_by=auth.uid() WHERE no = p_doc AND status = 'open';
  v_updated := FOUND;
  IF v_updated THEN PERFORM wms_log('IN_COMPLETE', p_doc); END IF;
  RETURN jsonb_build_object('ok', true, 'updated', v_updated);
END $function$;

-- Outbound
CREATE OR REPLACE FUNCTION public.wms_outbound_create(p_no text, p_customer text, p_phone text, p_address text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('picker','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  INSERT INTO outbound_docs(no, customer_name, customer_phone, customer_address) VALUES (p_no, trim(p_customer), p_phone, p_address);
  PERFORM wms_log('OUT_CREATE', p_no, jsonb_build_object('customer',trim(p_customer)));
  RETURN jsonb_build_object('ok', true, 'no', p_no);
END $function$;

-- Alokasi FEFO: pilih batch dengan ED paling dekat lebih dulu, isi outbound_picks
CREATE OR REPLACE FUNCTION public.fefo_allocate(p_doc text, p_sku text, p_qty integer)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE need int := p_qty; r record; take int; n int;
BEGIN
  IF auth.uid() IS NOT NULL AND coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  SELECT COALESCE(MAX(seq),0) INTO n FROM outbound_picks WHERE doc_no = p_doc;
  FOR r IN
    SELECT s.batch, s.expiry, s.rack_code,
           s.qty - COALESCE((SELECT SUM(k.qty - k.picked) FROM outbound_picks k JOIN outbound_docs d ON d.no = k.doc_no
                             WHERE d.status = 'open' AND k.sku = s.sku AND k.batch = s.batch AND k.rack_code = s.rack_code),0) AS avail
    FROM stock s WHERE s.sku = p_sku AND s.rack_code <> 'GR-STAGING' AND s.qty > 0
    ORDER BY s.expiry, s.batch, s.rack_code FOR UPDATE OF s
  LOOP
    EXIT WHEN need <= 0;
    CONTINUE WHEN r.avail <= 0;
    take := LEAST(need, r.avail); n := n + 1;
    INSERT INTO outbound_picks(doc_no,seq,sku,batch,expiry,rack_code,qty) VALUES (p_doc,n,p_sku,r.batch,r.expiry,r.rack_code,take);
    need := need - take;
  END LOOP;
  PERFORM wms_log('FEFO_ALLOCATE', p_doc, jsonb_build_object('sku',p_sku,'qty',p_qty,'sisa',need));
  RETURN need; -- sisa yang TIDAK bisa dialokasikan (0 = terpenuhi semua)
END $function$;

-- Catat 1 pick (mis. dari scan barcode di rak), menambah stock_movements dan mengurangi stock
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
  SELECT id, qty, picked INTO k FROM outbound_picks
   WHERE doc_no = p_doc AND sku = p_sku AND batch = p_batch AND rack_code = p_rack AND picked < qty
   ORDER BY seq LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Item tidak ada di picking list (SKU/batch/rak tidak sesuai)'; END IF;
  IF p_qty > k.qty - k.picked THEN RAISE EXCEPTION 'Melebihi sisa pick (% ctn)', k.qty - k.picked; END IF;
  INSERT INTO stock_movements(type,doc_no,sku,batch,from_rack,qty,user_id,scanned_at,idempotency_key)
    VALUES ('GI',p_doc,p_sku,p_batch,p_rack,p_qty,auth.uid(),p_scanned_at,p_key) ON CONFLICT (idempotency_key) DO NOTHING;
  IF NOT FOUND THEN RETURN jsonb_build_object('duplicate', true); END IF;
  UPDATE stock SET qty = qty - p_qty, updated_at = now() WHERE sku = p_sku AND batch = p_batch AND rack_code = p_rack AND qty >= p_qty;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stok % | % di rak % tidak cukup', p_sku, p_batch, p_rack; END IF;
  UPDATE outbound_picks SET picked = picked + p_qty WHERE id = k.id;
  PERFORM wms_log('GI_PICK', p_doc, jsonb_build_object('sku',p_sku,'batch',p_batch,'rack',p_rack,'qty',p_qty));
  RETURN jsonb_build_object('ok', true);
END $function$;

CREATE OR REPLACE FUNCTION public.wms_outbound_complete(p_doc text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_updated boolean;
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('picker','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF EXISTS (SELECT 1 FROM outbound_picks WHERE doc_no = p_doc AND picked < qty) THEN RAISE EXCEPTION 'Picking belum lengkap'; END IF;
  UPDATE outbound_docs SET status='done', completed_at=now(), completed_by=auth.uid() WHERE no = p_doc AND status = 'open';
  v_updated := FOUND;
  IF v_updated THEN PERFORM wms_log('OUT_COMPLETE', p_doc); END IF;
  RETURN jsonb_build_object('ok', true, 'updated', v_updated);
END $function$;

-- Mutasi antar rak
CREATE OR REPLACE FUNCTION public.wms_move(p_sku text, p_batch text, p_from text, p_to text, p_qty integer, p_scanned_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_key text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_exp date;
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'Jumlah harus lebih dari 0'; END IF;
  p_sku := upper(trim(p_sku)); p_batch := upper(trim(p_batch)); p_from := upper(trim(p_from)); p_to := upper(trim(p_to));
  IF p_from = p_to THEN RAISE EXCEPTION 'Rak asal dan tujuan sama'; END IF;
  IF NOT EXISTS (SELECT 1 FROM racks WHERE code = p_to AND active) THEN RAISE EXCEPTION 'Rak % tidak terdaftar', p_to; END IF;
  INSERT INTO stock_movements(type,sku,batch,from_rack,to_rack,qty,user_id,scanned_at,idempotency_key)
    VALUES ('MOVE',p_sku,p_batch,p_from,p_to,p_qty,auth.uid(),p_scanned_at,p_key) ON CONFLICT (idempotency_key) DO NOTHING;
  IF NOT FOUND THEN RETURN jsonb_build_object('duplicate', true); END IF;
  UPDATE stock SET qty = qty - p_qty, updated_at = now() WHERE sku = p_sku AND batch = p_batch AND rack_code = p_from AND qty >= p_qty
    RETURNING expiry INTO v_exp;
  IF NOT FOUND THEN RAISE EXCEPTION 'Stok % | % di rak % tidak cukup', p_sku, p_batch, p_from; END IF;
  INSERT INTO stock(sku,batch,expiry,rack_code,qty) VALUES (p_sku,p_batch,v_exp,p_to,p_qty)
    ON CONFLICT (sku,batch,rack_code) DO UPDATE SET qty = stock.qty + EXCLUDED.qty, updated_at = now();
  PERFORM wms_log('STOCK_MOVE', NULL, jsonb_build_object('sku',p_sku,'batch',p_batch,'from',p_from,'to',p_to,'qty',p_qty));
  RETURN jsonb_build_object('ok', true);
END $function$;

-- Stok Opname
CREATE OR REPLACE FUNCTION public.wms_opname_create(p_no text, p_sku text, p_counter text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  INSERT INTO opname_docs(no, sku, counter) VALUES (p_no, upper(trim(p_sku)), p_counter);
  INSERT INTO opname_lines(doc_no, batch, rack_code, qty_system)
    SELECT p_no, batch, rack_code, qty FROM stock WHERE sku = upper(trim(p_sku)) AND qty > 0;
  PERFORM wms_log('OPNAME_CREATE', p_no, jsonb_build_object('sku',upper(trim(p_sku)),'counter',p_counter));
  RETURN jsonb_build_object('ok', true, 'no', p_no);
END $function$;

CREATE OR REPLACE FUNCTION public.wms_opname_set_line(p_doc text, p_batch text, p_rack text, p_physical integer)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  UPDATE opname_lines SET qty_physical = p_physical WHERE doc_no=p_doc AND batch=upper(trim(p_batch)) AND rack_code=upper(trim(p_rack));
  PERFORM wms_log('OPNAME_SET_LINE', p_doc, jsonb_build_object('batch',upper(trim(p_batch)),'rack',upper(trim(p_rack)),'physical',p_physical));
  RETURN jsonb_build_object('ok', true);
END $function$;

CREATE OR REPLACE FUNCTION public.wms_opname_post(p_doc text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE r record; v_sku text; d int; n int := 0;
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  SELECT sku INTO v_sku FROM opname_docs WHERE no = p_doc AND status = 'open';
  IF v_sku IS NULL THEN RAISE EXCEPTION 'Sesi opname tidak ditemukan atau sudah selesai'; END IF;
  FOR r IN SELECT * FROM opname_lines WHERE doc_no = p_doc AND qty_physical IS NOT NULL LOOP
    d := r.qty_physical - r.qty_system;
    IF d <> 0 THEN
      n := n + 1;
      UPDATE stock SET qty = r.qty_physical, updated_at = now() WHERE sku = v_sku AND batch = r.batch AND rack_code = r.rack_code;
      INSERT INTO stock_movements(type,doc_no,sku,batch,to_rack,qty,user_id,reason)
        VALUES ('ADJ',p_doc,v_sku,r.batch,r.rack_code,d,auth.uid(),'Stok Opname '||p_doc);
    END IF;
  END LOOP;
  DELETE FROM stock WHERE sku = v_sku AND qty <= 0;
  UPDATE opname_docs SET status='done', completed_at=now(), completed_by=auth.uid() WHERE no = p_doc;
  PERFORM wms_log('OPNAME_POST', p_doc, jsonb_build_object('sku',v_sku,'baris_selisih',n));
  RETURN jsonb_build_object('ok', true, 'selisih', n);
END $function$;

-- Penyesuaian stok manual langsung (di luar sesi opname), wajib ada alasan
CREATE OR REPLACE FUNCTION public.wms_adjust(p_sku text, p_batch text, p_rack text, p_new_qty integer, p_reason text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_qty int; d int; v_no text;
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  IF p_new_qty IS NULL OR p_new_qty < 0 THEN RAISE EXCEPTION 'Jumlah baru tidak valid'; END IF;
  IF p_reason IS NULL OR trim(p_reason) = '' THEN RAISE EXCEPTION 'Alasan wajib diisi'; END IF;
  SELECT qty INTO v_qty FROM stock WHERE sku = upper(trim(p_sku)) AND batch = upper(trim(p_batch)) AND rack_code = upper(trim(p_rack)) FOR UPDATE;
  IF v_qty IS NULL THEN RAISE EXCEPTION 'Stok tidak ditemukan'; END IF;
  d := p_new_qty - v_qty;
  IF d = 0 THEN RETURN jsonb_build_object('ok', true, 'selisih', 0); END IF;
  v_no := 'ADJ-' || to_char(now(), 'YYYYMMDDHH24MISS');
  UPDATE stock SET qty = p_new_qty, updated_at = now() WHERE sku = upper(trim(p_sku)) AND batch = upper(trim(p_batch)) AND rack_code = upper(trim(p_rack));
  INSERT INTO stock_movements(type,doc_no,sku,batch,to_rack,qty,user_id,reason)
    VALUES ('ADJ',v_no,upper(trim(p_sku)),upper(trim(p_batch)),upper(trim(p_rack)),d,auth.uid(),trim(p_reason));
  DELETE FROM stock WHERE sku = upper(trim(p_sku)) AND batch = upper(trim(p_batch)) AND rack_code = upper(trim(p_rack)) AND qty <= 0;
  PERFORM wms_log('STOCK_ADJUST', v_no, jsonb_build_object('sku',upper(trim(p_sku)),'batch',upper(trim(p_batch)),'rack',upper(trim(p_rack)),'selisih',d,'reason',trim(p_reason)));
  RETURN jsonb_build_object('ok', true, 'selisih', d);
END $function$;

-- Trigger: buat baris profiles otomatis saat auth.users baru dibuat
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Trigger: catat setiap login berhasil ke activity_log
DROP TRIGGER IF EXISTS on_auth_user_login ON auth.users;
CREATE TRIGGER on_auth_user_login AFTER UPDATE ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.wms_log_login();

-- Event trigger platform Supabase: otomatis menyalakan RLS pada tabel baru di schema public
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog'
AS $function$
DECLARE cmd record;
BEGIN
  FOR cmd IN
    SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
     END IF;
  END LOOP;
END;
$function$;

-- Fungsi-fungsi ini HANYA dipanggil oleh trigger (bukan lewat REST/RPC),
-- jadi hak eksekusinya dicabut dari peran publik/login biasa.
REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.wms_log_login() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.wms_adjust(text,text,text,integer,text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.wms_opname_post(text) FROM anon;
