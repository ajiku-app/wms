-- ============================================================
-- MIGRASI v2.0.20 — Data proses MUAT saat menutup (close) Outbound
-- Alur: picker selesai pick -> barang ke staging area muat -> proses muat ->
--       checker menutup DO dan WAJIB mengisi: waktu mulai muat, waktu selesai muat,
--       no. kendaraan, nama ekspedisi, dan petugas muat.
-- Aman dijalankan sekali. Data DO lama (status done) tidak diubah (kolom baru = NULL).
-- WAJIB: pasang Scan v1.0.5 di semua HP (Scan lama menutup DO otomatis tanpa data muat -> ditolak server).
-- ============================================================

-- 1) Kolom baru
alter table public.outbound_docs
  add column if not exists load_start timestamptz,
  add column if not exists load_end   timestamptz,
  add column if not exists vehicle_no varchar,
  add column if not exists expedition varchar,
  add column if not exists loaders    text;

-- 2) Ganti fungsi close: tanda tangan lama (text, boolean) dihapus agar tidak ada fungsi ganda
drop function if exists public.wms_outbound_complete(text, boolean);

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

-- 3) Hak eksekusi (sama dengan fungsi aksi lain: hanya user login)
revoke execute on function public.wms_outbound_complete(text,boolean,timestamptz,timestamptz,text,text,text) from public, anon;
grant  execute on function public.wms_outbound_complete(text,boolean,timestamptz,timestamptz,text,text,text) to authenticated;

-- 4) Cek hasil: harus 1 baris, 7 argumen
select proname, pg_get_function_identity_arguments(oid) as args
from pg_proc where proname = 'wms_outbound_complete' and pronamespace = 'public'::regnamespace;
