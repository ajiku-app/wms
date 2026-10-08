-- ============================================================
-- functions.sql — SUMBER KEBENARAN fungsi database WMS (konsolidasi, kondisi v2.0.17 + hardening v2.0.18 + receive v2.0.19 + data muat v2.0.20)
-- ============================================================
-- File ini DIBANGUN ULANG dari seluruh migrasi (definisi terakhir yang menang), bukan dari database live:
--   functions.sql awal -> migrate_gr_batch -> migrate_wms_v2 -> v2_0_11 -> v2_0_12 -> migrate_pl_edit_delete
--   -> v2_0_13 -> v2_0_17.  Hasil: 47 fungsi, tanpa nama ganda. Tiap fungsi diberi komentar "-- [asal]".
--
-- CARA PAKAI
--  * Database BARU : jalankan schema.sql, policies.sql, lalu seluruh migrate_* sesuai urutan README.
--                    (File ini hasilnya sama dengan fungsi-fungsi itu; tidak wajib dijalankan.)
--  * Database LIVE : JANGAN dijalankan sebelum memverifikasi. Jalankan export-snapshot.sql (query 1 dan 6) dan
--                    bandingkan dengan file ini. Bila sama, file ini sah menjadi snapshot resmi. Bila berbeda,
--                    ekspor definisi live dan timpa file ini. Menjalankan file ini = MENIMPA fungsi live dengan
--                    isi di bawah (aman bila database sudah di v2.0.17, karena isinya identik).
--  * Prasyarat tabel: wms_freeze (dibuat oleh migrate_v2_0_17) harus sudah ada.
--  * Setelah ini JANGAN ada lagi fungsi di luar file ini. Fungsi baru: tambahkan di sini DAN buat migrasinya.
-- ============================================================

-- [migrate_v2_0_13_sinkron.sql]
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

-- [functions.sql]
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO profiles(id, name) VALUES (new.id, split_part(new.email,'@',1)) ON CONFLICT DO NOTHING;
  RETURN new;
END $function$;

-- [functions.sql]
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

-- [functions.sql]
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

-- [migrate_wms_v2.sql]
create or replace function public.wms_aging(p_days integer default 30) returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if wms_role() is null then raise exception 'Tidak berwenang'; end if;
  return jsonb_build_object(
    'skus', coalesce((select jsonb_agg(x order by x.sku) from (
      select sku, name,
        coalesce(sum(qty) filter (where d between 0 and 30),0)::int as b0,
        coalesce(sum(qty) filter (where d between 31 and 90),0)::int as b1,
        coalesce(sum(qty) filter (where d between 91 and 180),0)::int as b2,
        coalesce(sum(qty) filter (where d > 180),0)::int as b3,
        coalesce(sum(qty) filter (where d < 0),0)::int as exp
      from (select s.sku, p.name, s.qty, (s.expiry - wms_today()) as d from stock s join products p on p.sku = s.sku where s.qty > 0) z
      group by sku, name) x), '[]'::jsonb),
    'batches', coalesce((select jsonb_agg(y) from (
      select s.sku, s.batch, s.rack_code as rack, (s.expiry - wms_today()) as sisa, s.qty
      from stock s where s.qty > 0 and (s.expiry - wms_today()) <= greatest(coalesce(p_days,30),0)
      order by s.expiry, s.sku, s.batch) y), '[]'::jsonb));
end $function$;

-- [functions.sql]
CREATE OR REPLACE FUNCTION public.wms_customer_add(p_name text, p_phone text DEFAULT NULL::text, p_address text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('picker','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  INSERT INTO customers(name, phone, address) VALUES (trim(p_name), p_phone, p_address);
  PERFORM wms_log('CUSTOMER_ADD', NULL, jsonb_build_object('name',trim(p_name)));
  RETURN jsonb_build_object('ok', true);
END $function$;

-- [migrate_v2_0_17_pallet_freeze_staging.sql]
create or replace function public.wms_dashboard() returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_today date := wms_today(); v_total int; v_avail int; v_res int; v_exp int; v_stg int; v_hold int; v_full int;
begin
  if wms_role() is null then raise exception 'Tidak berwenang'; end if;
  select coalesce(sum(qty),0) into v_total from stock where qty > 0;
  select coalesce(sum(s.qty - wms_held(s.sku,s.batch,s.rack_code)),0) into v_avail from stock s
    where s.qty > 0 and s.rack_code <> 'GR-STAGING' and s.expiry >= v_today;
  select coalesce(sum(k.qty - k.picked),0) into v_res from outbound_picks k join outbound_docs d on d.no = k.doc_no where d.status = 'open';
  select count(*) into v_exp from stock where qty > 0 and expiry < v_today;
  select count(*) into v_stg from stock s where s.rack_code='GR-STAGING' and s.qty > 0 and
    coalesce((select max(m.moved_at) from stock_movements m where m.type='GR' and m.sku=s.sku and m.batch=s.batch and m.to_rack='GR-STAGING'), now()) < now() - interval '4 hours';
  select count(*) into v_hold from stock_holds where status = 'active';
  select count(*) into v_full from racks r where r.capacity > 0 and wms_rack_pallets(r.code) >= r.capacity;
  return jsonb_build_object(
    'total', v_total, 'available', greatest(v_avail - v_res, 0),
    'freeze', wms_is_frozen(),
    'inbound_open', (select count(*) from inbound_docs where status = 'open'),
    'outbound_open', (select count(*) from outbound_docs where status = 'open'),
    'exc', jsonb_build_object('expired', v_exp, 'staging', v_stg, 'hold', v_hold, 'rack_full', v_full),
    'exceptions', v_exp + v_stg + v_hold + v_full,
    'flow', (select jsonb_agg(f order by f.d) from (
      select g::date as d,
        coalesce(sum(m.qty) filter (where m.type='GR'),0)::int as "in",
        coalesce(sum(m.qty) filter (where m.type='GI'),0)::int as "out"
      from generate_series(v_today - 6, v_today, interval '1 day') g
      left join stock_movements m on m.type in ('GR','GI') and (m.moved_at at time zone 'Asia/Jakarta')::date = g::date
      group by g) f),
    'aging', (select jsonb_build_object(
        'b0', coalesce(sum(qty) filter (where d between 0 and 30),0), 'b1', coalesce(sum(qty) filter (where d between 31 and 90),0),
        'b2', coalesce(sum(qty) filter (where d between 91 and 180),0), 'b3', coalesce(sum(qty) filter (where d > 180),0),
        'exp', coalesce(sum(qty) filter (where d < 0),0))
      from (select qty, (expiry - v_today) as d from stock where qty > 0) z),
    'racks', wms_rack_load());
end $function$;

-- [migrate_v2_0_17_pallet_freeze_staging.sql]
create or replace function public.wms_freeze_set(p_active boolean, p_note text default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
begin
  if coalesce(wms_role(),'') not in ('admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  update wms_freeze set active = coalesce(p_active,false), note = nullif(trim(coalesce(p_note,'')),''),
         changed_by = auth.uid(), changed_at = now() where id = 1;
  perform wms_log(case when coalesce(p_active,false) then 'FREEZE_ON' else 'FREEZE_OFF' end, null,
                  jsonb_build_object('note', nullif(trim(coalesce(p_note,'')),'')));
  return jsonb_build_object('ok', true, 'active', coalesce(p_active,false));
end $function$;

-- [functions.sql]
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

-- [migrate_v2_0_17_pallet_freeze_staging.sql]
create or replace function public.wms_guard_movement() returns trigger
 language plpgsql security definer set search_path to 'public'
as $function$
begin
  if wms_is_frozen() then
    -- satu-satunya yang boleh saat freeze: posting selisih dari sesi opname yang masih terbuka
    if not (new.type = 'ADJ' and new.doc_no is not null
            and exists (select 1 from opname_docs where no = new.doc_no and status = 'open')) then
      raise exception 'Gudang sedang FREEZE (stok opname berlangsung). Transaksi stok ditolak sampai admin/supervisor menekan Unfreeze.';
    end if;
  end if;
  if new.type = 'GR' and new.to_rack is distinct from 'GR-STAGING' then
    raise exception 'Barang inbound wajib masuk GR-STAGING lebih dulu, lalu dipindah ke rak lewat Putaway.';
  end if;
  return new;
end $function$;

-- [migrate_wms_v2.sql]
create or replace function public.wms_held(p_sku text, p_batch text, p_rack text) returns integer
 language sql stable security definer set search_path to 'public'
as $$ select coalesce(sum(qty),0)::int from stock_holds where status='active' and sku=p_sku and batch=p_batch and rack_code=p_rack $$;

-- [migrate_wms_v2.sql]
create or replace function public.wms_hold_list() returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if coalesce(wms_role(),'') not in ('admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  return coalesce((select jsonb_agg(t order by t.sku, t.rack, t.batch) from (
    select s.sku, p.name, s.batch, s.rack_code as rack, s.expiry as ed, (s.expiry - wms_today()) as sisa, s.qty,
      wms_held(s.sku,s.batch,s.rack_code) as held,
      coalesce((select jsonb_agg(jsonb_build_object('id',h.id,'qty',h.qty,'reason',h.reason) order by h.id) from stock_holds h
        where h.status='active' and h.sku=s.sku and h.batch=s.batch and h.rack_code=s.rack_code), '[]'::jsonb) as holds
    from stock s join products p on p.sku = s.sku where s.qty > 0) t), '[]'::jsonb);
end $function$;

-- [migrate_wms_v2.sql]
create or replace function public.wms_hold_release(p_id bigint)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare h record;
begin
  if coalesce(wms_role(),'') not in ('admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  update stock_holds set status='released', released_by=auth.uid(), released_at=now() where id=p_id and status='active' returning * into h;
  if not found then raise exception 'Hold tidak ditemukan atau sudah dilepas'; end if;
  perform wms_log('HOLD_RELEASE', null, jsonb_build_object('sku',h.sku,'batch',h.batch,'rack',h.rack_code,'qty',h.qty,'reason',h.reason));
  return jsonb_build_object('ok', true);
end $function$;

-- [migrate_wms_v2.sql]
create or replace function public.wms_hold_set(p_sku text, p_batch text, p_rack text, p_qty integer, p_reason text, p_note text default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_qty int; v_res int; v_free int;
begin
  if coalesce(wms_role(),'') not in ('admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  p_sku := upper(trim(p_sku)); p_batch := upper(trim(p_batch)); p_rack := upper(trim(p_rack));
  if p_reason not in ('qc','retur','rusak','kedaluwarsa') then raise exception 'Alasan hold tidak valid'; end if;
  select qty into v_qty from stock where sku=p_sku and batch=p_batch and rack_code=p_rack for update;
  if v_qty is null then raise exception 'Stok tidak ditemukan'; end if;
  select coalesce(sum(k.qty - k.picked),0) into v_res from outbound_picks k join outbound_docs d on d.no = k.doc_no
    where d.status='open' and k.sku=p_sku and k.batch=p_batch and k.rack_code=p_rack;
  v_free := greatest(v_qty - wms_held(p_sku,p_batch,p_rack) - v_res, 0);
  if p_qty is null or p_qty <= 0 or p_qty > v_free then raise exception 'Jumlah hold harus 1 sampai % ctn (sisanya sudah di-hold / dialokasikan outbound)', v_free; end if;
  insert into stock_holds(sku,batch,rack_code,qty,reason,note,created_by) values (p_sku,p_batch,p_rack,p_qty,p_reason,nullif(trim(coalesce(p_note,'')),''),auth.uid());
  perform wms_log('HOLD_SET', null, jsonb_build_object('sku',p_sku,'batch',p_batch,'rack',p_rack,'qty',p_qty,'reason',p_reason));
  return jsonb_build_object('ok', true);
end $function$;

-- [functions.sql]
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

-- [migrate_gr_batch.sql]
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

-- [migrate_v2_0_19_receive_staging.sql]
create or replace function public.wms_inbound_receive_line(p_doc text, p_sku text, p_batch text, p_qty integer, p_rack text DEFAULT NULL::text, p_scanned_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_key text DEFAULT NULL::text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_status text; v_exp date; v_prod date; v_gr text; v_pl integer; v_rcv integer;
  v_sku text := upper(trim(p_sku)); v_batch text := upper(trim(p_batch));
  v_rack text := coalesce(nullif(upper(trim(coalesce(p_rack,''))),''),'GR-STAGING');
begin
  if coalesce(wms_role(),'') not in ('inbound','admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  if v_rack <> 'GR-STAGING' then
    raise exception 'Barang inbound wajib masuk GR-STAGING lebih dulu. Penempatan ke rak % dilakukan lewat Putaway (per pallet).', v_rack;
  end if;
  select status into v_status from inbound_docs where no = p_doc for update;
  if v_status is null then raise exception 'Dokumen inbound tidak ditemukan'; end if;
  if v_status <> 'open' then raise exception 'Dokumen sudah selesai'; end if;
  select expiry, production_date, gr_no, qty_pl, qty_received into v_exp, v_prod, v_gr, v_pl, v_rcv from inbound_lines
    where doc_no = p_doc and sku = v_sku and batch = v_batch for update;
  if v_exp is null then raise exception 'Baris item tidak ditemukan di dokumen ini (tidak ada di Packing List)'; end if;

  insert into stock_movements(type,doc_no,sku,batch,expiry,to_rack,qty,user_id,scanned_at,idempotency_key,gr_no)
    values ('GR',p_doc,v_sku,v_batch,v_exp,'GR-STAGING',p_qty,auth.uid(),p_scanned_at,p_key,v_gr)
    on conflict (idempotency_key) do nothing;
  if not found then return jsonb_build_object('duplicate', true); end if;

  -- RAISE membatalkan seluruh transaksi (termasuk stock_movements di atas)
  if v_rcv + p_qty > v_pl then
    raise exception 'Jumlah diterima melebihi Jumlah PL (PL %, sudah diterima %, sisa %)', v_pl, v_rcv, greatest(v_pl - v_rcv, 0);
  end if;

  update inbound_lines set qty_received = qty_received + p_qty, rack_code = 'GR-STAGING', pic = auth.uid()
    where doc_no = p_doc and sku = v_sku and batch = v_batch;
  insert into stock(sku,batch,expiry,production_date,rack_code,qty)
    values (v_sku,v_batch,v_exp,v_prod,'GR-STAGING',p_qty)
    on conflict (sku,batch,rack_code) do update set qty = stock.qty + excluded.qty,
      expiry = excluded.expiry, production_date = excluded.production_date, updated_at = now();
  perform wms_log('GR_RECEIVE', p_doc, jsonb_build_object('sku',v_sku,'batch',v_batch,'qty',p_qty,'rack','GR-STAGING'));
  return jsonb_build_object('ok', true);
end $function$;

-- [migrate_v2_0_17_pallet_freeze_staging.sql]
create or replace function public.wms_is_frozen() returns boolean
 language sql stable security definer set search_path to 'public'
as $$ select coalesce((select active from wms_freeze where id = 1), false) $$;

-- [functions.sql]
CREATE OR REPLACE FUNCTION public.wms_log(p_action text, p_doc text DEFAULT NULL::text, p_detail jsonb DEFAULT '{}'::jsonb)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO activity_log(user_id,user_name,user_role,action,doc_no,detail)
  SELECT auth.uid(), pr.name, pr.role, p_action, p_doc, coalesce(p_detail,'{}'::jsonb)
  FROM profiles pr WHERE pr.id = auth.uid();
END $function$;

-- [functions.sql]
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

-- [migrate_v2_0_17_pallet_freeze_staging.sql]
create or replace function public.wms_move(p_sku text, p_batch text, p_from text, p_to text, p_qty integer, p_scanned_at timestamptz default null, p_key text default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_exp date; v_prod date; v_qty int; v_cap int; v_used int; v_res int; v_held int;
begin
  if coalesce(wms_role(),'') not in ('inbound','admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  p_sku := upper(trim(p_sku)); p_batch := upper(trim(p_batch)); p_from := upper(trim(p_from)); p_to := upper(trim(p_to));
  if p_from = p_to then raise exception 'Rak asal dan tujuan sama'; end if;
  -- kunci baris rak tujuan: dua pemindahan ke rak yang sama diproses bergantian (kapasitas tidak bisa terlewati)
  select capacity into v_cap from racks where code = p_to and active for update;
  if not found then raise exception 'Rak % tidak terdaftar atau nonaktif', p_to; end if;
  select qty, expiry, production_date into v_qty, v_exp, v_prod from stock
    where sku = p_sku and batch = p_batch and rack_code = p_from for update;
  if v_qty is null or v_qty <= 0 then raise exception 'Pallet % | % tidak ada di rak %', p_sku, p_batch, p_from; end if;
  if p_qty is not null and p_qty <> v_qty then
    raise exception 'Pindah dilakukan per PALLET: harus seluruh isi pallet (% ctn), bukan % ctn', v_qty, p_qty;
  end if;
  v_held := wms_held(p_sku, p_batch, p_from);
  if v_held > 0 then raise exception 'Pallet % | % sedang di-hold (% ctn). Lepas hold dulu sebelum dipindah.', p_sku, p_batch, v_held; end if;
  select coalesce(sum(k.qty - k.picked),0) into v_res from outbound_picks k join outbound_docs d on d.no = k.doc_no
    where d.status = 'open' and k.sku = p_sku and k.batch = p_batch and k.rack_code = p_from;
  if v_res > 0 then raise exception 'Pallet % | % sudah dialokasikan ke outbound yang masih terbuka (% ctn). Selesaikan picking dulu.', p_sku, p_batch, v_res; end if;
  -- kapasitas: pallet baru menambah 1 di rak tujuan (menggabung ke pallet yang sama di tujuan tidak menambah)
  if v_cap > 0 and not exists (select 1 from stock where sku = p_sku and batch = p_batch and rack_code = p_to and qty > 0) then
    select count(*) into v_used from stock where rack_code = p_to and qty > 0;
    if v_used + 1 > v_cap then raise exception 'Rak % penuh (% dari % pallet)', p_to, v_used, v_cap; end if;
  end if;
  insert into stock_movements(type,doc_no,sku,batch,expiry,from_rack,to_rack,qty,user_id,scanned_at,idempotency_key)
    values ('MOVE', case when p_from = 'GR-STAGING' then 'PUTAWAY' end, p_sku,p_batch,v_exp,p_from,p_to,v_qty,auth.uid(),p_scanned_at,p_key)
    on conflict (idempotency_key) do nothing;
  if not found then return jsonb_build_object('duplicate', true); end if;
  delete from stock where sku = p_sku and batch = p_batch and rack_code = p_from;
  insert into stock(sku,batch,expiry,production_date,rack_code,qty) values (p_sku,p_batch,v_exp,v_prod,p_to,v_qty)
    on conflict (sku,batch,rack_code) do update set qty = stock.qty + excluded.qty, updated_at = now();
  perform wms_log('STOCK_MOVE', null, jsonb_build_object('sku',p_sku,'batch',p_batch,'from',p_from,'to',p_to,'qty',v_qty,'pallet',1));
  return jsonb_build_object('ok', true);
end $function$;

-- [migrate_v2_0_13_sinkron.sql]
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

-- [functions.sql]
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

-- [migrate_v2_0_13_sinkron.sql]
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

-- [functions.sql]
CREATE OR REPLACE FUNCTION public.wms_opname_set_line(p_doc text, p_batch text, p_rack text, p_physical integer)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  UPDATE opname_lines SET qty_physical = p_physical WHERE doc_no=p_doc AND batch=upper(trim(p_batch)) AND rack_code=upper(trim(p_rack));
  PERFORM wms_log('OPNAME_SET_LINE', p_doc, jsonb_build_object('batch',upper(trim(p_batch)),'rack',upper(trim(p_rack)),'physical',p_physical));
  RETURN jsonb_build_object('ok', true);
END $function$;

-- [migrate_v2_0_20_outbound_muat.sql]
create or replace function public.wms_outbound_complete(
  p_doc text,
  p_allow_short boolean default false,
  p_load_start timestamptz default null,
  p_load_end timestamptz default null,
  p_vehicle text default null,
  p_expedition text default null,
  p_loaders text default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_updated boolean; v_role text := wms_role(); v_req int; v_picked int; v_short boolean;
  v_veh text := upper(regexp_replace(trim(coalesce(p_vehicle,'')), '\s+', ' ', 'g'));
  v_exp text := trim(coalesce(p_expedition,''));
  v_ldr text := trim(coalesce(p_loaders,''));
begin
  if coalesce(v_role,'') not in ('picker','admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  if not exists (select 1 from outbound_docs where no = p_doc) then raise exception 'Dokumen outbound tidak ditemukan'; end if;
  if not exists (select 1 from outbound_picks where doc_no = p_doc) then
    raise exception 'Picking list masih kosong (belum ada barang yang dialokasikan)';
  end if;
  if exists (select 1 from outbound_picks where doc_no = p_doc and picked < qty) then raise exception 'Picking belum lengkap'; end if;

  -- data muat (wajib)
  if p_load_start is null or p_load_end is null then raise exception 'Data muat wajib diisi: waktu mulai dan selesai muat'; end if;
  if p_load_end <= p_load_start then raise exception 'Waktu selesai muat harus setelah waktu mulai muat'; end if;
  if p_load_end > now() + interval '10 minutes' then raise exception 'Waktu selesai muat tidak boleh di masa depan'; end if;
  if v_veh = '' then raise exception 'No. kendaraan wajib diisi'; end if;
  if length(v_veh) > 20 then raise exception 'No. kendaraan terlalu panjang (maks 20 karakter)'; end if;
  if v_exp = '' then raise exception 'Nama ekspedisi wajib diisi'; end if;
  if length(v_exp) > 100 then raise exception 'Nama ekspedisi terlalu panjang (maks 100 karakter)'; end if;
  if v_ldr = '' then raise exception 'Petugas muat wajib diisi'; end if;
  if length(v_ldr) > 200 then raise exception 'Nama petugas muat terlalu panjang (maks 200 karakter)'; end if;

  select coalesce(sum(qty),0) into v_req from outbound_items where doc_no = p_doc;
  select coalesce(sum(picked),0) into v_picked from outbound_picks where doc_no = p_doc;
  select exists (select 1 from outbound_items i where i.doc_no = p_doc
                 and i.qty > coalesce((select sum(k.picked) from outbound_picks k where k.doc_no = i.doc_no and k.sku = i.sku),0))
    into v_short;
  if v_short and not (coalesce(p_allow_short,false) and v_role in ('admin','supervisor')) then
    raise exception 'Pesanan belum terpenuhi penuh (diminta % ctn, terambil % ctn). Alokasikan sisa setelah stok tersedia, atau minta admin/supervisor menyelesaikan sebagian dari WMS.', v_req, v_picked;
  end if;

  update outbound_docs set status='done', completed_at=now(), completed_by=auth.uid(),
         load_start=p_load_start, load_end=p_load_end, vehicle_no=v_veh, expedition=v_exp, loaders=v_ldr
   where no = p_doc and status = 'open';
  v_updated := found;
  if v_updated then
    perform wms_log('OUT_COMPLETE', p_doc, jsonb_build_object('diminta',v_req,'terambil',v_picked,'sebagian',v_short,
      'muat_mulai',p_load_start,'muat_selesai',p_load_end,'kendaraan',v_veh,'ekspedisi',v_exp,'petugas_muat',v_ldr));
  end if;
  return jsonb_build_object('ok', true, 'updated', v_updated, 'short', v_short);
end $function$;

-- [migrate_v2_0_13_sinkron.sql]
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

-- [migrate_v2_0_12_outbound_items.sql]
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

-- [migrate_v2_0_13_sinkron.sql]
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

-- [migrate_v2_0_17_pallet_freeze_staging.sql]
create or replace function public.wms_pl_add_line(p_pl text, p_sku text, p_batch text, p_production date, p_expiry date, p_qty integer, p_gr text DEFAULT NULL::text)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_sku text := upper(trim(p_sku)); v_batch text := upper(trim(p_batch));
begin
  if coalesce(wms_role(),'') not in ('inbound','admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  if not exists (select 1 from packing_lists where no=p_pl and status='open') then raise exception 'Packing List tidak ditemukan atau sudah dipakai'; end if;
  if not exists (select 1 from products where sku=v_sku and active) then raise exception 'SKU % belum terdaftar di master produk', v_sku; end if;
  if exists (select 1 from packing_list_lines where pl_no=p_pl and sku=v_sku and batch=v_batch) then
    raise exception 'Baris SKU % dengan batch % sudah ada di Packing List ini', v_sku, v_batch;
  end if;
  if v_batch ~ '^[0-9]{8}\.[0-9]{3}$' and exists (select 1 from packing_list_lines where sku=v_sku and batch=v_batch) then
    raise exception 'Nomor pallet % untuk SKU % sudah pernah dipakai (tidak boleh ganda). Muat ulang nomor batch.', v_batch, v_sku;
  end if;
  insert into packing_list_lines(pl_no, sku, batch, production_date, expiry, qty, gr_no)
    values (p_pl, v_sku, v_batch, p_production, p_expiry, p_qty, nullif(upper(trim(coalesce(p_gr,''))),''));
  perform wms_log('PL_ADD_LINE', p_pl, jsonb_build_object('sku',v_sku,'batch',v_batch,'qty',p_qty,'gr_no',nullif(upper(trim(coalesce(p_gr,''))),'')));
  return jsonb_build_object('ok', true);
end $function$;

-- [functions.sql]
CREATE OR REPLACE FUNCTION public.wms_pl_create(p_no text, p_supplier text, p_doc_date date DEFAULT CURRENT_DATE)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  INSERT INTO packing_lists(no, supplier, doc_date, created_by) VALUES (p_no, trim(p_supplier), p_doc_date, auth.uid());
  PERFORM wms_log('PL_CREATE', p_no, jsonb_build_object('supplier',trim(p_supplier),'doc_date',p_doc_date));
  RETURN jsonb_build_object('ok', true, 'no', p_no);
END $function$;

-- [migrate_pl_edit_delete.sql]
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

-- [migrate_pl_edit_delete.sql]
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

-- [functions.sql]
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

-- [migrate_v2_0_17_pallet_freeze_staging.sql]
create or replace function public.wms_putaway(p_sku text, p_batch text, p_rack text, p_qty integer default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_sku text := upper(trim(p_sku)); v_batch text := upper(trim(p_batch)); v_rack text := upper(trim(p_rack)); v_q int; r jsonb;
begin
  if coalesce(wms_role(),'') not in ('inbound','admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  if v_rack = 'GR-STAGING' then raise exception 'Pilih rak tujuan selain GR-STAGING'; end if;
  select qty into v_q from stock where sku = v_sku and batch = v_batch and rack_code = 'GR-STAGING' and qty > 0;
  if v_q is null then raise exception 'Pallet % | % tidak ada di GR-STAGING', v_sku, v_batch; end if;
  r := wms_move(v_sku, v_batch, 'GR-STAGING', v_rack, null);   -- selalu satu pallet utuh (p_qty diabaikan)
  perform wms_log('PUTAWAY', null, jsonb_build_object('sku',v_sku,'batch',v_batch,'rack',v_rack,'qty',v_q,'pallet',1));
  return r;
end $function$;

-- [migrate_v2_0_13_sinkron.sql]
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

-- [migrate_v2_0_17_pallet_freeze_staging.sql]
create or replace function public.wms_rack_load() returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if wms_role() is null then raise exception 'Tidak berwenang'; end if;
  return coalesce((select jsonb_agg(t order by t.code) from (
    select r.code, r.zone, r.capacity, r.active, count(s.id)::int as used,
           coalesce(array_agg(distinct s.sku) filter (where s.id is not null), '{}') as skus
    from racks r left join stock s on s.rack_code = r.code and s.qty > 0
    group by r.code, r.zone, r.capacity, r.active) t), '[]'::jsonb);
end $function$;

-- [migrate_v2_0_17_pallet_freeze_staging.sql]
create or replace function public.wms_rack_pallets(p_rack text) returns integer
 language sql stable security definer set search_path to 'public'
as $$ select count(*)::int from stock where rack_code = p_rack and qty > 0 $$;

-- [functions.sql]
CREATE OR REPLACE FUNCTION public.wms_rack_set_active(p_code text, p_active boolean)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  UPDATE racks SET active = p_active WHERE code = upper(trim(p_code));
  PERFORM wms_log('RACK_SET_ACTIVE', NULL, jsonb_build_object('code',upper(trim(p_code)),'active',p_active));
  RETURN jsonb_build_object('ok', true);
END $function$;

-- [migrate_wms_v2.sql]
create or replace function public.wms_rack_set_capacity(p_code text, p_capacity integer)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
begin
  if coalesce(wms_role(),'') not in ('admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  if p_capacity is null or p_capacity < 0 then raise exception 'Kapasitas tidak valid'; end if;
  update racks set capacity = p_capacity where code = upper(trim(p_code));
  if not found then raise exception 'Rak tidak ditemukan'; end if;
  perform wms_log('RACK_SET_CAPACITY', null, jsonb_build_object('code',upper(trim(p_code)),'capacity',p_capacity));
  return jsonb_build_object('ok', true);
end $function$;

-- [functions.sql]
CREATE OR REPLACE FUNCTION public.wms_role()
 RETURNS text
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$ SELECT role FROM profiles WHERE id = auth.uid() AND active $function$;

-- [functions.sql]
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

-- [migrate_wms_v2.sql]
create or replace function public.wms_staging_pending() returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if coalesce(wms_role(),'') not in ('inbound','admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  return coalesce((select jsonb_agg(t order by t.hours desc) from (
    select s.sku, p.name, s.batch, s.expiry, s.qty, wms_held(s.sku,s.batch,s.rack_code) as held,
      round((extract(epoch from now() - coalesce((select max(m.moved_at) from stock_movements m
        where m.type='GR' and m.sku=s.sku and m.batch=s.batch and m.to_rack='GR-STAGING'), s.updated_at)) / 3600)::numeric, 1) as hours
    from stock s join products p on p.sku = s.sku
    where s.rack_code = 'GR-STAGING' and s.qty > 0) t), '[]'::jsonb);
end $function$;

-- [migrate_wms_v2.sql]
create or replace function public.wms_stock_page(p_q text default '', p_status text default '', p_limit integer default 8, p_offset integer default 0, p_sort text default 'sku', p_dir text default 'asc')
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_col text; v_dir text; v_lim int := least(greatest(coalesce(p_limit,8),1),500); v_off int := greatest(coalesce(p_offset,0),0); res jsonb;
begin
  if wms_role() is null then raise exception 'Tidak berwenang'; end if;
  v_col := case p_sort when 'name' then 'name' when 'batch' then 'batch' when 'rack' then 'rack' when 'ed' then 'ed' when 'sisa' then 'sisa' when 'ctn' then 'ctn' when 'status' then 'status' else 'sku' end;
  v_dir := case when lower(coalesce(p_dir,'')) = 'desc' then 'desc' else 'asc' end;
  execute format($q$
    with b as (
      select s.sku, p.name, s.batch, s.rack_code as rack, s.expiry as ed, (s.expiry - wms_today()) as sisa, s.qty as ctn,
        case when wms_held(s.sku,s.batch,s.rack_code) > 0 then 'hold'
             when s.expiry < wms_today() then 'exp' when s.expiry - wms_today() <= 90 then 'near' else 'Aman' end as status
      from stock s join products p on p.sku = s.sku where s.qty > 0),
    f as (select * from b where ($1 = '' or (sku||' '||name||' '||batch||' '||rack) ilike '%%'||$1||'%%') and ($2 = '' or status = $2))
    select jsonb_build_object('total', (select count(*) from f),
      'rows', coalesce((select jsonb_agg(t) from (select * from f order by %I %s, sku, batch, rack limit %s offset %s) t), '[]'::jsonb))
  $q$, v_col, v_dir, v_lim, v_off) into res using coalesce(p_q,''), coalesce(p_status,'');
  return res;
end $function$;

-- [functions.sql]
CREATE OR REPLACE FUNCTION public.wms_supplier_add(p_name text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('inbound','admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  INSERT INTO suppliers(name) VALUES (trim(p_name));
  PERFORM wms_log('SUPPLIER_ADD', NULL, jsonb_build_object('name',trim(p_name)));
  RETURN jsonb_build_object('ok', true);
END $function$;

-- [migrate_wms_v2.sql]
create or replace function public.wms_today() returns date language sql stable
as $$ select (now() at time zone 'Asia/Jakarta')::date $$;

-- [functions.sql]
CREATE OR REPLACE FUNCTION public.wms_user_set_active(p_user uuid, p_active boolean)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF coalesce(wms_role(),'') NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Tidak berwenang'; END IF;
  UPDATE profiles SET active = p_active WHERE id = p_user;
  PERFORM wms_log('USER_SET_ACTIVE', NULL, jsonb_build_object('target_user',p_user,'active',p_active));
  RETURN jsonb_build_object('ok', true);
END $function$;

-- ============================================================
-- TRIGGER
-- ============================================================
-- Buat baris profiles otomatis saat auth.users baru dibuat
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Catat setiap login berhasil ke activity_log
DROP TRIGGER IF EXISTS on_auth_user_login ON auth.users;
CREATE TRIGGER on_auth_user_login AFTER UPDATE ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.wms_log_login();

-- Penjaga buku besar: FREEZE opname + inbound wajib GR-STAGING (v2.0.17)
DROP TRIGGER IF EXISTS trg_guard_movement ON public.stock_movements;
CREATE TRIGGER trg_guard_movement BEFORE INSERT ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.wms_guard_movement();
-- (rls_auto_enable adalah event trigger bawaan platform Supabase; dipasang oleh platform, bukan di sini.)

-- ============================================================
-- HAK EKSEKUSI (v2.0.18)
-- ============================================================
-- 1) Semua fungsi: cabut dari PUBLIC dan anon, beri ke authenticated
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f' LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
  END LOOP;
END $$;
-- 2) Fungsi INTERNAL (hanya dipanggil trigger atau fungsi security definer lain) tidak boleh bisa dipanggil lewat RPC.
--    wms_log khususnya: bila terbuka, user mana pun bisa memalsukan entri log aktivitas.
REVOKE EXECUTE ON FUNCTION public.handle_new_user()        FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.wms_log_login()          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable()        FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.wms_guard_movement()     FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.wms_log(text,text,jsonb) FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
