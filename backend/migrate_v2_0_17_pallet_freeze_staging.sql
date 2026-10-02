-- ============================================================
-- MIGRASI v2.0.17 — Freeze opname, inbound wajib staging, kapasitas per PALLET,
-- pindah/putaway per PALLET, nomor pallet tidak boleh ganda.
-- Jalankan SEKALI di Supabase SQL Editor SETELAH migrate_v2_0_16 (aman dijalankan ulang). BACKUP DULU.
-- SEBELUM menjalankan: jalankan export-snapshot.sql (query 1) dan bandingkan definisi live
-- wms_move, wms_putaway, wms_rack_load, wms_dashboard, wms_pl_add_line dengan repo (temuan K2),
-- karena migrasi ini menggantinya.
--
-- Keputusan yang diterapkan:
--   T7  Tombol FREEZE/UNFREEZE: saat freeze, semua transaksi stok (terima, pick, pindah, putaway,
--       penyesuaian) ditolak di level buku besar (trigger pada stock_movements), kecuali posting opname.
--       Hold/QC TETAP BOLEH saat freeze: hanya mengunci stok di sistem, tidak memindahkan barang
--       (tidak menulis stock_movements).
--   T4  Hasil produksi (inbound) SELALU masuk GR-STAGING; ke rak hanya lewat Putaway/Mutasi.
--   KAP Kapasitas rak = jumlah PALLET per bin loc (mis. A-01-01 muat 3 pallet), bukan ctn.
--       1 pallet = 1 baris stok (SKU + batch). Pindah/putaway selalu satu pallet utuh.
--       Pallet yang sebagian sudah di-pick tetap dihitung SATU pallet sampai qty habis (baris dihapus).
--   R3  Pallet fisik bersifat umum (dipakai ulang untuk produk lain): tidak ada master pallet yang
--       terikat SKU. Identitas muatan = SKU + batch (YYYYMMDD.NNN); baris stok dihapus saat habis.
--   DUP Nomor pallet/batch format YYYYMMDD.NNN tidak boleh ganda per SKU (index unik + cek fungsi).
-- ============================================================
begin;

-- ---------- 1) FREEZE ----------
create table if not exists public.wms_freeze(
  id int primary key default 1 check (id = 1),
  active boolean not null default false,
  note text,
  changed_by uuid references public.profiles(id),
  changed_at timestamptz not null default now()
);
insert into public.wms_freeze(id) values (1) on conflict (id) do nothing;
alter table public.wms_freeze enable row level security;
drop policy if exists p_freeze on public.wms_freeze;
create policy p_freeze on public.wms_freeze for select to authenticated using (wms_role() is not null);
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='wms_freeze') then
    alter publication supabase_realtime add table public.wms_freeze;
  end if;
end $$;

create or replace function public.wms_is_frozen() returns boolean
 language sql stable security definer set search_path to 'public'
as $$ select coalesce((select active from wms_freeze where id = 1), false) $$;

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

-- ---------- 2) PENJAGA BUKU BESAR (berlaku untuk WMS web, aplikasi scan, dan jalur apa pun) ----------
-- Semua perubahan stok fisik menulis ke stock_movements; RAISE di sini membatalkan seluruh transaksi.
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
drop trigger if exists trg_guard_movement on public.stock_movements;
create trigger trg_guard_movement before insert on public.stock_movements
  for each row execute function public.wms_guard_movement();

-- ---------- 3) KAPASITAS PER PALLET ----------
-- Satuan lama = ctn. Dikonversi SEKALI: bin loc = 3 pallet (sesuai kondisi saat ini); GR-STAGING & NON-RACK = tidak dibatasi.
-- Setelah ini ubah per rak lewat Master > Rak bila ada bin yang berbeda.
do $$
declare v_c text;
begin
  select col_description('public.racks'::regclass, a.attnum) into v_c
  from pg_attribute a where a.attrelid = 'public.racks'::regclass and a.attname = 'capacity';
  if v_c is null or v_c not like 'Kapasitas bin loc dalam PALLET%' then
    update public.racks set capacity = 3 where code not in ('GR-STAGING','NON-RACK');
    update public.racks set capacity = 0 where code in ('GR-STAGING','NON-RACK');
    comment on column public.racks.capacity is 'Kapasitas bin loc dalam PALLET (0 = tidak dibatasi)';
  end if;
end $$;

create or replace function public.wms_rack_pallets(p_rack text) returns integer
 language sql stable security definer set search_path to 'public'
as $$ select count(*)::int from stock where rack_code = p_rack and qty > 0 $$;

-- Beban rak: used = jumlah PALLET di rak
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

-- ---------- 4) PINDAH / PUTAWAY PER PALLET ----------
-- p_qty tetap ada demi kompatibilitas panggilan lama: null = seluruh pallet; selain itu harus sama dengan isi pallet.
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

-- ---------- 5) DASHBOARD: rak penuh dihitung per pallet; tambah status freeze ----------
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

-- ---------- 6) NOMOR PALLET (BATCH YYYYMMDD.NNN) TIDAK BOLEH GANDA ----------
do $$
begin
  if exists (select 1 from public.packing_list_lines where batch ~ '^[0-9]{8}\.[0-9]{3}$' group by sku, batch having count(*) > 1) then
    raise warning 'LEWATI unique pallet: ada nomor pallet ganda. Cek: SELECT sku,batch,count(*),array_agg(pl_no) FROM packing_list_lines WHERE batch ~ ''^[0-9]{8}\.[0-9]{3}$'' GROUP BY 1,2 HAVING count(*)>1;';
  else
    create unique index if not exists ux_pl_lines_sku_batch_pallet on public.packing_list_lines(sku, batch)
      where batch ~ '^[0-9]{8}\.[0-9]{3}$';
  end if;
end $$;

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

-- ---------- 7) Hak eksekusi ----------
revoke execute on function public.wms_is_frozen() from public, anon;
revoke execute on function public.wms_freeze_set(boolean,text) from public, anon;
revoke execute on function public.wms_guard_movement() from public, anon, authenticated;
revoke execute on function public.wms_rack_pallets(text) from public, anon;
revoke execute on function public.wms_rack_load() from public, anon;
revoke execute on function public.wms_move(text,text,text,text,integer,timestamptz,text) from public, anon;
revoke execute on function public.wms_putaway(text,text,text,integer) from public, anon;
revoke execute on function public.wms_dashboard() from public, anon;
revoke execute on function public.wms_pl_add_line(text,text,text,date,date,integer,text) from public, anon;
grant execute on function public.wms_is_frozen() to authenticated;
grant execute on function public.wms_freeze_set(boolean,text) to authenticated;
grant execute on function public.wms_rack_pallets(text) to authenticated;
grant execute on function public.wms_rack_load() to authenticated;
grant execute on function public.wms_move(text,text,text,text,integer,timestamptz,text) to authenticated;
grant execute on function public.wms_putaway(text,text,text,integer) to authenticated;
grant execute on function public.wms_dashboard() to authenticated;
grant execute on function public.wms_pl_add_line(text,text,text,date,date,integer,text) to authenticated;

commit;
notify pgrst, 'reload schema';

-- ---------- Cek hasil (hanya membaca) ----------
-- 1) Rak yang SUDAH melebihi kapasitas pallet (data lama): perlu dipindah / kapasitas disesuaikan di Master > Rak
select r.code, r.capacity as kapasitas_pallet, wms_rack_pallets(r.code) as pallet_terisi,
       case when wms_rack_pallets(r.code) > r.capacity then 'MELEBIHI KAPASITAS' else 'OK' end as status
from racks r where r.capacity > 0 and wms_rack_pallets(r.code) > r.capacity order by 1;
-- 2) Pallet yang terbelah di lebih dari satu rak (sisa pindah parsial dari versi lama): harus disatukan
select sku, batch, count(*) as jumlah_rak, array_agg(rack_code) as rak
from stock where qty > 0 group by sku, batch having count(*) > 1 order by 1, 2;
-- 3) Status freeze & trigger
select (select active from wms_freeze where id = 1) as freeze_aktif,
       exists (select 1 from pg_trigger where tgname = 'trg_guard_movement' and not tgisinternal) as trigger_ada;
