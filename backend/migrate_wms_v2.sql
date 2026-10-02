-- ============================================================
-- MIGRASI v2 — Putaway, Hold & Karantina, Kapasitas Rak, Dashboard, Aging/ED,
-- Informasi Stok server-side, Kartu Stok. Jalankan SEKALI di SQL Editor (backup dulu).
-- Setelah schema.sql, policies.sql, functions.sql, migrate_gr_batch.sql.
-- ============================================================
begin;

-- 1) Kapasitas rak (ctn). 0 = belum diisi (tidak dibatasi, prioritas terakhir saat putaway)
alter table public.racks add column if not exists capacity integer not null default 0 check (capacity >= 0);
update public.racks set capacity = 400 where code = 'GR-STAGING' and capacity = 0;

-- 2) Buku besar: ADJ boleh negatif (selisih opname/penyesuaian). Sebelumnya check qty>0 menolak ADJ negatif.
alter table public.stock_movements drop constraint if exists stock_movements_qty_check;
alter table public.stock_movements add constraint stock_movements_qty_check check (qty <> 0 and (type = 'ADJ' or qty > 0));

-- 3) Hold & karantina (per SKU + batch + rak, boleh sebagian)
create table if not exists public.stock_holds(
  id bigint generated always as identity primary key,
  sku varchar not null references public.products(sku),
  batch varchar not null,
  rack_code varchar not null references public.racks(code),
  qty integer not null check (qty > 0),
  reason varchar not null check (reason in ('qc','retur','rusak','kedaluwarsa')),
  note text,
  status varchar not null default 'active' check (status in ('active','released')),
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  released_by uuid references public.profiles(id),
  released_at timestamptz
);
create index if not exists stock_holds_active_idx on public.stock_holds(sku, batch, rack_code) where status = 'active';
alter table public.stock_holds enable row level security;
drop policy if exists p_holds on public.stock_holds;
create policy p_holds on public.stock_holds for select to authenticated using (wms_role() is not null);
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='stock_holds') then
    alter publication supabase_realtime add table public.stock_holds;
  end if;
end $$;

-- 4) Helper
create or replace function public.wms_today() returns date language sql stable
as $$ select (now() at time zone 'Asia/Jakarta')::date $$;

create or replace function public.wms_held(p_sku text, p_batch text, p_rack text) returns integer
 language sql stable security definer set search_path to 'public'
as $$ select coalesce(sum(qty),0)::int from stock_holds where status='active' and sku=p_sku and batch=p_batch and rack_code=p_rack $$;

-- 5) Master rak: kapasitas
drop function if exists public.wms_rack_add(text,text);
create or replace function public.wms_rack_add(p_code text, p_zone text, p_capacity integer default 0)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
begin
  if coalesce(wms_role(),'') not in ('admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  if coalesce(p_capacity,0) < 0 then raise exception 'Kapasitas tidak valid'; end if;
  insert into racks(code, zone, capacity) values (upper(trim(p_code)), p_zone, coalesce(p_capacity,0));
  perform wms_log('RACK_ADD', null, jsonb_build_object('code',upper(trim(p_code)),'zone',p_zone,'capacity',coalesce(p_capacity,0)));
  return jsonb_build_object('ok', true);
end $function$;

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

-- 6) Beban rak (dipakai Dashboard & Putaway)
create or replace function public.wms_rack_load() returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if wms_role() is null then raise exception 'Tidak berwenang'; end if;
  return coalesce((select jsonb_agg(t order by t.code) from (
    select r.code, r.zone, r.capacity, r.active, coalesce(sum(s.qty),0)::int as used,
           coalesce(array_agg(distinct s.sku) filter (where s.qty > 0), '{}') as skus
    from racks r left join stock s on s.rack_code = r.code and s.qty > 0
    group by r.code, r.zone, r.capacity, r.active) t), '[]'::jsonb);
end $function$;

-- 7) Antrian putaway (isi GR-STAGING)
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

-- 8) Mutasi antar rak: hormati hold & kapasitas; dari GR-STAGING otomatis tercatat sebagai PUTAWAY
create or replace function public.wms_move(p_sku text, p_batch text, p_from text, p_to text, p_qty integer, p_scanned_at timestamptz default null, p_key text default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_exp date; v_prod date; v_qty int; v_cap int; v_used int;
begin
  if coalesce(wms_role(),'') not in ('inbound','admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Jumlah harus lebih dari 0'; end if;
  p_sku := upper(trim(p_sku)); p_batch := upper(trim(p_batch)); p_from := upper(trim(p_from)); p_to := upper(trim(p_to));
  if p_from = p_to then raise exception 'Rak asal dan tujuan sama'; end if;
  select capacity into v_cap from racks where code = p_to and active;
  if not found then raise exception 'Rak % tidak terdaftar', p_to; end if;
  select qty, expiry, production_date into v_qty, v_exp, v_prod from stock
    where sku = p_sku and batch = p_batch and rack_code = p_from for update;
  if v_qty is null or v_qty - wms_held(p_sku,p_batch,p_from) < p_qty then
    raise exception 'Stok bebas % | % di rak % tidak cukup (stok yang di-hold tidak bisa dipindah)', p_sku, p_batch, p_from; end if;
  if v_cap > 0 then
    select coalesce(sum(qty),0) into v_used from stock where rack_code = p_to;
    if v_used + p_qty > v_cap then raise exception 'Kapasitas rak % tidak cukup (sisa % ctn)', p_to, greatest(v_cap - v_used, 0); end if;
  end if;
  insert into stock_movements(type,doc_no,sku,batch,expiry,from_rack,to_rack,qty,user_id,scanned_at,idempotency_key)
    values ('MOVE', case when p_from = 'GR-STAGING' then 'PUTAWAY' end, p_sku,p_batch,v_exp,p_from,p_to,p_qty,auth.uid(),p_scanned_at,p_key)
    on conflict (idempotency_key) do nothing;
  if not found then return jsonb_build_object('duplicate', true); end if;
  update stock set qty = qty - p_qty, updated_at = now() where sku=p_sku and batch=p_batch and rack_code=p_from;
  delete from stock where sku=p_sku and batch=p_batch and rack_code=p_from and qty <= 0;
  insert into stock(sku,batch,expiry,production_date,rack_code,qty) values (p_sku,p_batch,v_exp,v_prod,p_to,p_qty)
    on conflict (sku,batch,rack_code) do update set qty = stock.qty + excluded.qty, updated_at = now();
  perform wms_log('STOCK_MOVE', null, jsonb_build_object('sku',p_sku,'batch',p_batch,'from',p_from,'to',p_to,'qty',p_qty));
  return jsonb_build_object('ok', true);
end $function$;

create or replace function public.wms_putaway(p_sku text, p_batch text, p_rack text, p_qty integer default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_free int; v_sku text := upper(trim(p_sku)); v_batch text := upper(trim(p_batch)); v_rack text := upper(trim(p_rack)); r jsonb;
begin
  if coalesce(wms_role(),'') not in ('inbound','admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  if v_rack = 'GR-STAGING' then raise exception 'Pilih rak tujuan selain GR-STAGING'; end if;
  select qty - wms_held(v_sku, v_batch, 'GR-STAGING') into v_free from stock where sku=v_sku and batch=v_batch and rack_code='GR-STAGING';
  if v_free is null or v_free <= 0 then raise exception 'Tidak ada stok bebas di GR-STAGING untuk item ini'; end if;
  r := wms_move(v_sku, v_batch, 'GR-STAGING', v_rack, coalesce(p_qty, v_free));
  perform wms_log('PUTAWAY', null, jsonb_build_object('sku',v_sku,'batch',v_batch,'rack',v_rack,'qty',coalesce(p_qty, v_free)));
  return r;
end $function$;

-- 9) Hold & karantina
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

-- 10) FEFO: lewati batch kedaluwarsa dan stok hold
create or replace function public.fefo_allocate(p_doc text, p_sku text, p_qty integer)
 returns integer language plpgsql security definer set search_path to 'public'
as $function$
declare need int := p_qty; r record; take int; n int;
begin
  if auth.uid() is not null and coalesce(wms_role(),'') not in ('admin','supervisor') then raise exception 'Tidak berwenang'; end if;
  select coalesce(max(seq),0) into n from outbound_picks where doc_no = p_doc;
  for r in
    select s.batch, s.expiry, s.rack_code,
      s.qty - wms_held(s.sku,s.batch,s.rack_code)
            - coalesce((select sum(k.qty - k.picked) from outbound_picks k join outbound_docs d on d.no = k.doc_no
                        where d.status='open' and k.sku=s.sku and k.batch=s.batch and k.rack_code=s.rack_code),0) as avail
    from stock s where s.sku = p_sku and s.rack_code <> 'GR-STAGING' and s.qty > 0 and s.expiry >= wms_today()
    order by s.expiry, s.batch, s.rack_code for update of s
  loop
    exit when need <= 0;
    continue when r.avail <= 0;
    take := least(need, r.avail); n := n + 1;
    insert into outbound_picks(doc_no,seq,sku,batch,expiry,rack_code,qty) values (p_doc,n,p_sku,r.batch,r.expiry,r.rack_code,take);
    need := need - take;
  end loop;
  perform wms_log('FEFO_ALLOCATE', p_doc, jsonb_build_object('sku',p_sku,'qty',p_qty,'sisa',need));
  return need;
end $function$;

-- 11) Informasi Stok: filter, sort, dan paging di server -> {total, rows}
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

-- 12) Aging & ED
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

-- 13) Dashboard
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
  select count(*) into v_full from racks r where r.capacity > 0 and (select coalesce(sum(qty),0) from stock where rack_code = r.code) >= r.capacity * 0.9;
  return jsonb_build_object(
    'total', v_total, 'available', greatest(v_avail - v_res, 0),
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

commit;
