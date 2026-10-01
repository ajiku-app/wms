-- ============================================================
-- BACKEND — SCHEMA (Supabase Postgres)
-- Gudang FG — Serena Indopapangan
-- Diekspor dari struktur yang BENAR-BENAR berjalan di project
-- Supabase "wms" (kiqthmniiibofulbmbun) pada saat file ini dibuat.
-- Jalankan di project Supabase baru lewat SQL Editor / CLI kalau
-- perlu memindahkan atau membuat ulang backend ini.
-- ============================================================

-- Profil pengguna (1 baris per akun auth.users, dibuat otomatis oleh trigger handle_new_user)
create table public.profiles(
  id uuid primary key references auth.users(id),
  name text not null,
  role text check (role = any (array['inbound','picker','admin','supervisor'])),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Master produk
create table public.products(
  sku varchar primary key,
  name varchar not null,
  pcs_per_ctn integer not null default 1 check (pcs_per_ctn > 0),
  active boolean not null default true
);

-- Master rak
create table public.racks(
  code varchar primary key,
  zone varchar,
  description text,
  active boolean not null default true
);

-- Master pemasok & customer
create table public.suppliers(
  id bigint generated always as identity primary key,
  name varchar not null unique,
  active boolean not null default true
);
create table public.customers(
  id bigint generated always as identity primary key,
  name varchar not null unique,
  phone varchar,
  address text,
  active boolean not null default true
);

-- Stok on-hand (satu baris per SKU + batch + rak)
create table public.stock(
  id bigint generated always as identity primary key,
  sku varchar not null references public.products(sku),
  batch varchar not null,
  expiry date,
  production_date date,
  rack_code varchar not null references public.racks(code),
  qty integer not null check (qty >= 0),
  updated_at timestamptz not null default now(),
  unique (sku, batch, rack_code)
);

-- Packing List (dari pemasok, sebelum Inbound)
create table public.packing_lists(
  no varchar primary key,
  supplier varchar not null,
  doc_date date not null default current_date,
  status varchar not null default 'open' check (status in ('open','used')),
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id)
);
create table public.packing_list_lines(
  id bigint generated always as identity primary key,
  pl_no varchar not null references public.packing_lists(no),
  sku varchar not null references public.products(sku),
  batch varchar not null,
  production_date date,
  expiry date not null,
  qty integer not null check (qty > 0),
  gr_no varchar  -- No GR / Inventory Transfer SAP (hanya untuk tracking, tidak dicetak di label)
);

-- Inbound (dibuat dari satu Packing List)
create table public.inbound_docs(
  no varchar primary key,
  packing_list varchar,
  supplier varchar,
  doc_date date not null default current_date,
  status varchar not null default 'open' check (status in ('open','done')),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  completed_by uuid references public.profiles(id)
);
create table public.inbound_lines(
  id bigint generated always as identity primary key,
  doc_no varchar not null references public.inbound_docs(no),
  sku varchar not null references public.products(sku),
  batch varchar not null,
  expiry date not null,
  production_date date,
  qty_pl integer not null check (qty_pl >= 0),
  qty_received integer not null default 0 check (qty_received >= 0),
  rack_code varchar references public.racks(code),
  pic uuid references public.profiles(id),
  gr_no varchar  -- dari packing list
);

-- Outbound (header pesanan customer)
create table public.outbound_docs(
  no varchar primary key,
  doc_date date not null default current_date,
  customer_name varchar,
  customer_phone varchar,
  customer_address text,
  status varchar not null default 'open' check (status in ('open','done')),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  completed_by uuid references public.profiles(id)
);
-- Item pesanan outbound (SKU + jumlah yang diminta) — v2.0.12
create table public.outbound_items(
  doc_no varchar not null references public.outbound_docs(no),
  sku varchar not null references public.products(sku),
  qty integer not null check (qty > 0),
  primary key (doc_no, sku)
);
-- Hasil alokasi FEFO per baris (dibuat oleh fungsi fefo_allocate)
create table public.outbound_picks(
  id bigint generated always as identity primary key,
  doc_no varchar not null references public.outbound_docs(no),
  seq integer not null,
  sku varchar not null references public.products(sku),
  batch varchar not null,
  expiry date not null,
  rack_code varchar not null references public.racks(code),
  qty integer not null check (qty > 0),
  picked integer not null default 0
);

-- Stok Opname (hitung fisik per SKU)
create table public.opname_docs(
  no varchar primary key,
  doc_date date not null default current_date,
  sku varchar not null references public.products(sku),
  counter varchar,
  status varchar not null default 'open' check (status in ('open','done')),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  completed_by uuid references public.profiles(id)
);
create table public.opname_lines(
  id bigint generated always as identity primary key,
  doc_no varchar not null references public.opname_docs(no),
  batch varchar not null,
  rack_code varchar not null references public.racks(code),
  qty_system integer not null,
  qty_physical integer
);

-- Buku besar semua pergerakan stok (GR=inbound, GI=outbound, MOVE=mutasi, ADJ=penyesuaian/opname)
create table public.stock_movements(
  id bigint generated always as identity primary key,
  moved_at timestamptz not null default now(),
  type varchar not null check (type in ('GR','GI','MOVE','ADJ')),
  doc_no varchar,
  sku varchar not null references public.products(sku),
  batch varchar not null,
  expiry date,
  from_rack varchar references public.racks(code),
  to_rack varchar references public.racks(code),
  qty integer not null check (qty > 0),
  user_id uuid not null references public.profiles(id),
  scanned_at timestamptz,
  idempotency_key varchar unique,
  reason text,
  gr_no varchar  -- No GR SAP (tipe GR)
);

-- Rak wajib untuk staging barang masuk sebelum ditempatkan (dipakai sebagai default oleh fungsi backend)
insert into public.racks(code, zone, description) values ('GR-STAGING','GR','Area sementara barang masuk')
  on conflict (code) do nothing;

-- Log aktivitas (audit trail). Diisi otomatis oleh wms_log() dari dalam setiap
-- fungsi aksi, dan oleh trigger wms_log_login saat seseorang login. Tabel ini
-- SENGAJA tidak punya policy SELECT sama sekali (lihat policies.sql) — satu-
-- satunya jalan membaca isinya adalah lewat fungsi wms_get_activity_log().
create table public.activity_log(
  id bigint generated always as identity primary key,
  user_id uuid references public.profiles(id),
  user_name text,
  user_role text,
  action text not null,
  doc_no text,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
