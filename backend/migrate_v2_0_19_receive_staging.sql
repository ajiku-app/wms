-- ============================================================
-- MIGRASI v2.0.19 — wms_inbound_receive_line: inbound HANYA ke GR-STAGING, pesan error jelas.
-- Jalankan SEKALI setelah v2.0.17/18 (aman diulang). Signature tidak berubah (p_rack tetap ada agar APK/web lama tidak error 404),
-- tetapi rak selain GR-STAGING ditolak dengan pesan yang jelas. Logika kapasitas lama (hitung ctn) dihapus: kapasitas kini
-- per PALLET dan hanya diperiksa saat Putaway/Pindah (wms_move).
-- ============================================================
begin;
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
revoke execute on function public.wms_inbound_receive_line(text,text,text,integer,text,timestamptz,text) from public, anon;
grant execute on function public.wms_inbound_receive_line(text,text,text,integer,text,timestamptz,text) to authenticated;
commit;
notify pgrst, 'reload schema';

-- Cek: index nomor pallet unik harus ADA (bila tidak ada, v2.0.17 melewatinya karena ada data ganda; jalankan ulang v2.0.17 setelah data dibersihkan)
select indexname, indexdef from pg_indexes where indexname = 'ux_pl_lines_sku_batch_pallet';
