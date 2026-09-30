-- ============================================================
-- BACKEND — ROW LEVEL SECURITY
-- Semua tabel: hanya bisa DIBACA langsung (policy SELECT), dan
-- hanya oleh pengguna yang sudah login dan punya role aktif.
-- Semua PERUBAHAN DATA wajib lewat fungsi di functions.sql
-- (SECURITY DEFINER) yang mengecek role di dalamnya. Tidak ada
-- policy INSERT/UPDATE/DELETE langsung — ini disengaja.
-- ============================================================

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.racks enable row level security;
alter table public.suppliers enable row level security;
alter table public.customers enable row level security;
alter table public.stock enable row level security;
alter table public.packing_lists enable row level security;
alter table public.packing_list_lines enable row level security;
alter table public.inbound_docs enable row level security;
alter table public.inbound_lines enable row level security;
alter table public.outbound_docs enable row level security;
alter table public.outbound_picks enable row level security;
alter table public.opname_docs enable row level security;
alter table public.opname_lines enable row level security;
alter table public.stock_movements enable row level security;

-- profiles: pengguna bisa lihat dirinya sendiri, dan siapapun yang sudah
-- punya role bisa lihat semua profil (untuk memilih PIC, dsb.)
create policy p_profiles on public.profiles for select
  using (id = auth.uid() or wms_role() is not null);

create policy p_products on public.products for select using (wms_role() is not null);
create policy p_racks    on public.racks    for select using (wms_role() is not null);
create policy p_suppliers on public.suppliers for select using (wms_role() is not null);
create policy p_customers on public.customers for select using (wms_role() is not null);
create policy p_stock    on public.stock    for select using (wms_role() is not null);

create policy p_pl       on public.packing_lists      for select using (wms_role() = any(array['inbound','admin','supervisor']));
create policy p_pl_lines on public.packing_list_lines  for select using (wms_role() = any(array['inbound','admin','supervisor']));
create policy p_in_docs  on public.inbound_docs        for select using (wms_role() = any(array['inbound','admin','supervisor']));
create policy p_in_lines on public.inbound_lines       for select using (wms_role() = any(array['inbound','admin','supervisor']));

create policy p_out_docs on public.outbound_docs  for select using (wms_role() = any(array['picker','admin','supervisor']));
create policy p_out_pick on public.outbound_picks for select using (wms_role() = any(array['picker','admin','supervisor']));

create policy p_opname_docs  on public.opname_docs  for select using (wms_role() = any(array['admin','supervisor']));
create policy p_opname_lines on public.opname_lines for select using (wms_role() = any(array['admin','supervisor']));

create policy p_moves on public.stock_movements for select using (wms_role() = any(array['admin','supervisor']));

-- activity_log: RLS dinyalakan TANPA policy sama sekali (baris ini yang
-- membuatnya begitu — tidak ada "create policy" untuk tabel ini). Efeknya:
-- tabel ini 100% tertutup dari REST langsung, untuk siapa pun termasuk admin.
-- Satu-satunya jalan baca adalah RPC wms_get_activity_log(), yang menyaring
-- baris sendiri untuk role biasa dan semua baris untuk admin/supervisor.
alter table public.activity_log enable row level security;
