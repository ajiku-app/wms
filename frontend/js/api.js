// ============================================================
// LAPISAN API — satu-satunya file yang boleh bicara ke backend.
// Semua file "views/*.js" memanggil fungsi di sini, TIDAK PERNAH
// memanggil `sb.from()` / `sb.rpc()` langsung. Kalau suatu saat
// backend diganti (mis. dari Supabase ke server Express sendiri),
// cukup file INI yang ditulis ulang — seluruh frontend lain tetap
// jalan tanpa diubah, karena bentuk kontraknya sama.
// Kontrak tiap fungsi didokumentasikan di /API.md.
// ============================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { SUPABASE_URL, SUPABASE_ANON } from './config.js';

// Di aplikasi desktop (Electron) sesi login disimpan lewat file, bukan localStorage,
// agar tidak hilang saat aplikasi ditutup. Di browser/PWA memakai localStorage bawaan.
const desk = typeof window !== 'undefined' ? window.desktopStore : null;
const lsGet = k => { try { return localStorage.getItem(k); } catch (e) { return null; } };
const lsDel = k => { try { localStorage.removeItem(k); } catch (e) {} };
const deskStorage = desk ? {
  getItem: async k => (await desk.get(k)) ?? lsGet(k),
  setItem: (k, v) => desk.set(k, v),
  removeItem: async k => { lsDel(k); await desk.remove(k); }
} : null;

// Versi aplikasi desktop (null jika dibuka di browser/PWA)
export const appVersion = async () => { try { return desk && desk.version ? await desk.version() : null; } catch (e) { return null; } };

export const sb = createClient(SUPABASE_URL, SUPABASE_ANON,
  deskStorage ? { auth: { storage: deskStorage, persistSession: true, autoRefreshToken: true } } : undefined);

function unwrap({ data, error, count }) {
  if (error) throw error;
  return count != null ? { data, count } : data;

}

// Ambil SEMUA baris (PostgREST membatasi 1000 baris per request) -> loop per 1000.
// mk() harus mengembalikan query builder BARU dengan order() yang stabil.
async function all(mk) {
  const out = [];
  for (let f = 0; ; f += 1000) {
    const d = await mk().range(f, f + 999).then(unwrap);
    out.push(...(d || []));
    if (!d || d.length < 1000) break;
  }
  return out;
}

// Auto refresh: dengarkan perubahan data (Supabase Realtime). Hak baca mengikuti RLS user.
export function subscribeChanges(onChange, onStatus) {
  const ch = sb.channel('wms-live').on('postgres_changes', { event: '*', schema: 'public' }, onChange)
    .subscribe((st) => onStatus && onStatus(st));
  return () => sb.removeChannel(ch);
}

export const auth = {
  getSession: async () => (await sb.auth.getSession()).data.session,
  onChange: (cb) => sb.auth.onAuthStateChange(cb),
  signIn: (email, password) => sb.auth.signInWithPassword({ email, password }),
  signUp: (email, password) => sb.auth.signUp({ email, password }),
  signOut: () => sb.auth.signOut(),
};

// Cache kode warehouse per (sku|batch): 'FG-01', ... ('' = tidak diketahui)
const _bw = new Map();

export const api = {
  // ---- util nomor dokumen ----
  docExists: (table, no) => sb.from(table).select('no').eq('no', no).maybeSingle().then(r => { if (r.error) throw r.error; return !!r.data; }),

  // ---- profil & pengguna ----
  myProfile: (id) => sb.from('profiles').select('id,name,role,active').eq('id', id).maybeSingle().then(unwrap),
  listProfiles: () => sb.from('profiles').select('id,name,role,active').order('name').then(unwrap),
  setUserRole: (userId, role) => sb.rpc('wms_set_role', { p_user: userId, p_role: role }).then(unwrap),
  setUserActive: (userId, active) => sb.rpc('wms_user_set_active', { p_user: userId, p_active: active }).then(unwrap),

  // ---- dashboard ----
  countActiveProducts: () => sb.from('products').select('*', { count: 'exact', head: true }).eq('active', true).then(unwrap),
  listRacksBrief: () => all(() => sb.from('racks').select('code,active').order('code')),
  listInboundStatus: () => sb.from('inbound_docs').select('no,status').then(unwrap),
  listOutboundStatus: () => sb.from('outbound_docs').select('no,status').then(unwrap),
  listStockForDashboard: () => all(() => sb.from('stock').select('sku,qty,expiry,products(name)').order('expiry').order('sku').order('batch').order('rack_code')),

  // ---- master: produk ----
  listProducts: () => sb.from('products').select('sku,name,pcs_per_ctn,active').order('sku').then(unwrap),
  listActiveProducts: () => sb.from('products').select('sku,name').eq('active', true).order('sku').then(unwrap),
  addProduct: (sku, name, pcsPerCtn) => sb.rpc('wms_product_add', { p_sku: sku, p_name: name, p_cpp: pcsPerCtn }).then(unwrap),

  // ---- master: rak ----
  listRacks: () => all(() => sb.from('racks').select('code,zone,capacity,active').order('code')),
  listActiveRacks: () => sb.from('racks').select('code').eq('active', true).order('code').then(unwrap),
  addRack: (code, zone, capacity = 0) => sb.rpc('wms_rack_add', { p_code: code, p_zone: zone, p_capacity: capacity }).then(unwrap),
  setRackCapacity: (code, capacity) => sb.rpc('wms_rack_set_capacity', { p_code: code, p_capacity: capacity }).then(unwrap),
  setRackActive: (code, active) => sb.rpc('wms_rack_set_active', { p_code: code, p_active: active }).then(unwrap),

  // ---- master: pemasok & customer ----
  listSuppliers: () => sb.from('suppliers').select('name,active,Whs').order('name').then(unwrap),
  listActiveSuppliers: () => sb.from('suppliers').select('name,Whs').eq('active', true).then(unwrap),
  addSupplier: (name) => sb.rpc('wms_supplier_add', { p_name: name }).then(unwrap),
  listCustomers: () => sb.from('customers').select('name,phone,address,active').order('name').then(unwrap),
  listActiveCustomers: () => sb.from('customers').select('name,phone,address').eq('active', true).then(unwrap),
  addCustomer: (name, phone, address) => sb.rpc('wms_customer_add', { p_name: name, p_phone: phone, p_address: address }).then(unwrap),

  // ---- packing list ----
  listPackingLists: () => sb.from('packing_lists').select('no,supplier,doc_date,status').order('created_at', { ascending: false }).then(unwrap),
  listOpenPackingLists: () => sb.from('packing_lists').select('no,supplier').eq('status', 'open').then(unwrap),
  getPackingList: (no) => sb.from('packing_lists').select('*').eq('no', no).single().then(unwrap),
  listPackingListLines: (no) => sb.from('packing_list_lines').select('*,products(name)').eq('pl_no', no).then(unwrap),
  // No GR per Packing List (gr_no ada di baris/line) -> { [pl_no]: ['GR1','GR2'] }
  packingListGr: async () => { const d = await sb.from('packing_list_lines').select('pl_no,gr_no').not('gr_no', 'is', null).then(unwrap); const m = {}; (d || []).forEach(r => { const a = (m[r.pl_no] = m[r.pl_no] || []); if (!a.includes(r.gr_no)) a.push(r.gr_no); }); return m; },
  updatePackingList: (no, supplier, docDate, gr) => sb.rpc('wms_pl_update', { p_no: no, p_supplier: supplier, p_doc_date: docDate, p_gr: gr || null }).then(unwrap),
  deletePackingList: (no) => sb.rpc('wms_pl_delete', { p_no: no }).then(unwrap),
  countPackingLists: () => sb.from('packing_lists').select('no', { count: 'exact', head: true }).then(unwrap),
  createPackingList: (no, supplier, docDate) => sb.rpc('wms_pl_create', { p_no: no, p_supplier: supplier, p_doc_date: docDate }).then(unwrap),
  addPackingListLine: (pl, sku, batch, productionDate, expiry, qty, gr) =>
    sb.rpc('wms_pl_add_line', { p_pl: pl, p_sku: sku, p_batch: batch, p_production: productionDate || null, p_expiry: expiry, p_qty: qty, p_gr: gr || null }).then(unwrap),
  // nomor urut batch berikutnya untuk SKU + tanggal ED (mis. 20270930.001 -> .002)
  // v2.0.13: nomor batch dihitung di server (melihat PL open, inbound, stok & riwayat). Fallback ke hitungan klien bila fungsi belum ada.
  nextBatchSeq: async (sku, ymd) => { try { const r = await sb.rpc('wms_next_batch_seq', { p_sku: sku, p_ymd: ymd }); if (!r.error && r.data != null) return String(r.data).padStart(3, '0'); } catch (e) {} return api.nextBatchSeqLocal(sku, ymd); },
  nextBatchSeqLocal: async (sku, ymd) => { try { const d = await sb.from('packing_list_lines').select('batch').eq('sku', sku).like('batch', ymd + '.%').then(unwrap); const n = Math.max(0, ...(d || []).map(r => parseInt(String(r.batch).split('.').pop(), 10) || 0)); return String(n + 1).padStart(3, '0'); } catch (e) { return '001'; } },

  // ---- inbound ----
  listInboundDocs: () => sb.from('inbound_docs').select('no,doc_date,supplier,status').order('created_at', { ascending: false }).then(unwrap),
  getInboundDoc: (no) => sb.from('inbound_docs').select('*').eq('no', no).single().then(unwrap),
  listInboundLines: (no) => sb.from('inbound_lines').select('*,products(name,pcs_per_ctn)').eq('doc_no', no).then(unwrap),
  countInboundDocs: () => sb.from('inbound_docs').select('no', { count: 'exact', head: true }).then(unwrap),
  createInboundFromPL: (no, pl) => sb.rpc('wms_inbound_create', { p_no: no, p_pl: pl }).then(unwrap),
  receiveInboundLine: (doc, sku, batch, qty, rack) =>
    sb.rpc('wms_inbound_receive_line', { p_doc: doc, p_sku: sku, p_batch: batch, p_qty: qty, p_rack: rack }).then(unwrap),
  completeInbound: (no) => sb.rpc('wms_inbound_complete', { p_doc: no }).then(unwrap),

  // ---- outbound ----
  listOutboundDocs: () => sb.from('outbound_docs').select('no,doc_date,customer_name,status,whs').order('created_at', { ascending: false }).then(unwrap),
  getOutboundDoc: (no) => sb.from('outbound_docs').select('*').eq('no', no).single().then(unwrap),
  listOutboundPicks: (no) => sb.from('outbound_picks').select('*,products(name)').eq('doc_no', no).order('seq').then(unwrap),
  countOutboundDocs: () => sb.from('outbound_docs').select('no', { count: 'exact', head: true }).then(unwrap),
  listOutboundItems: (no) => sb.from('outbound_items').select('sku,qty').eq('doc_no', no).then(unwrap),
  setOutboundItems: (no, items) => sb.rpc('wms_outbound_set_items', { p_doc: no, p_items: items }).then(unwrap),
  createOutboundDoc: (no, customer, phone, address, whs) =>
    sb.rpc('wms_outbound_create', { p_no: no, p_customer: customer, p_phone: phone, p_address: address, p_whs: whs || null }).then(unwrap),
  fefoAllocate: (doc, sku, qty) => sb.rpc('fefo_allocate', { p_doc: doc, p_sku: sku, p_qty: qty }).then(unwrap),
  pick: (doc, sku, batch, rack, qty) => sb.rpc('wms_pick', { p_doc: doc, p_sku: sku, p_batch: batch, p_rack: rack, p_qty: qty }).then(unwrap),
  completeOutbound: (no, allowShort = false) => sb.rpc('wms_outbound_complete', { p_doc: no, p_allow_short: !!allowShort }).then(unwrap),

  // ---- mutasi ----
  listStockForMove: () => sb.from('stock').select('sku,batch,rack_code,qty').gt('qty', 0).order('rack_code').then(unwrap),
  listMoveHistory: () => sb.from('stock_movements').select('moved_at,sku,batch,from_rack,to_rack,qty').eq('type', 'MOVE').order('moved_at', { ascending: false }).limit(10).then(unwrap),
  moveStock: (sku, batch, from, to, qty) => sb.rpc('wms_move', { p_sku: sku, p_batch: batch, p_from: from, p_to: to, p_qty: qty }).then(unwrap),

  // ---- stok ----
  listStock: () => all(() => sb.from('stock').select('sku,batch,rack_code,expiry,production_date,qty,products(name,pcs_per_ctn)').gt('qty', 0).order('expiry').order('sku').order('batch').order('rack_code')),

  // ---- stok opname ----
  listOpnameDocs: () => sb.from('opname_docs').select('no,doc_date,sku,status').order('created_at', { ascending: false }).then(unwrap),
  getOpnameDoc: (no) => sb.from('opname_docs').select('*').eq('no', no).single().then(unwrap),
  listOpnameLines: (no) => sb.from('opname_lines').select('*').eq('doc_no', no).then(unwrap),
  countOpnameDocs: () => sb.from('opname_docs').select('no', { count: 'exact', head: true }).then(unwrap),
  createOpname: (no, sku, counter) => sb.rpc('wms_opname_create', { p_no: no, p_sku: sku, p_counter: counter }).then(unwrap),
  setOpnameLine: (doc, batch, rack, physical) => sb.rpc('wms_opname_set_line', { p_doc: doc, p_batch: batch, p_rack: rack, p_physical: physical }).then(unwrap),
  postOpname: (doc) => sb.rpc('wms_opname_post', { p_doc: doc }).then(unwrap),

  // ---- penyesuaian stok ----
  listStockForAdjust: () => sb.from('stock').select('sku,batch,rack_code,qty').gt('qty', 0).order('sku').then(unwrap),
  listAdjustLog: () => sb.from('stock_movements').select('moved_at,doc_no,sku,batch,to_rack,qty').eq('type', 'ADJ').order('moved_at', { ascending: false }).limit(15).then(unwrap),
  adjustStock: (sku, batch, rack, newQty, reason) =>
    sb.rpc('wms_adjust', { p_sku: sku, p_batch: batch, p_rack: rack, p_new_qty: newQty, p_reason: reason }).then(unwrap),

  // ---- report ----
  listStockMovements: (limit = 500) =>
    sb.from('stock_movements').select('moved_at,type,doc_no,sku,batch,gr_no,from_rack,to_rack,qty').order('moved_at', { ascending: false }).limit(limit).then(unwrap),

  // ---- activity log (audit trail) ----
  // Tabel activity_log tertutup total (tidak ada policy SELECT sama sekali);
  // satu-satunya jalan baca adalah lewat RPC ini. Admin/supervisor melihat
  // semua baris, role lain hanya melihat baris miliknya sendiri.
  getActivityLog: (limit = 100, before = null) => sb.rpc('wms_get_activity_log', { p_limit: limit, p_before: before }).then(unwrap),

  // ---- v2: dashboard, stok server-side, putaway, hold, kartu stok, aging ----
  dashboard: () => sb.rpc('wms_dashboard').then(unwrap),
  rackLoad: () => sb.rpc('wms_rack_load').then(unwrap),
  stockByRack: (code) => sb.from('stock').select('sku,batch,expiry,qty,products(name)').eq('rack_code', code).gt('qty', 0).order('expiry').then(unwrap),
  stockPage: (o) => sb.rpc('wms_stock_page', { p_q: o.q, p_status: o.st, p_limit: o.lim, p_offset: o.off, p_sort: o.sort, p_dir: o.dir }).then(unwrap),
  stagingPending: () => sb.rpc('wms_staging_pending').then(unwrap),
  putaway: (sku, batch, rack, qty) => sb.rpc('wms_putaway', { p_sku: sku, p_batch: batch, p_rack: rack, p_qty: qty }).then(unwrap),
  stockCard: (sku) => sb.from('stock_movements').select('moved_at,type,doc_no,qty,batch').eq('sku', sku).order('moved_at').order('id').limit(1000).then(unwrap),
  holdList: () => sb.rpc('wms_hold_list').then(unwrap),
  holdSet: (sku, batch, rack, qty, reason, note) => sb.rpc('wms_hold_set', { p_sku: sku, p_batch: batch, p_rack: rack, p_qty: qty, p_reason: reason, p_note: note || null }).then(unwrap),
  holdRelease: (id) => sb.rpc('wms_hold_release', { p_id: id }).then(unwrap),
  aging: (days) => sb.rpc('wms_aging', { p_days: days }).then(unwrap),

  // ---- warehouse: kode FG-01.. disimpan di kolom suppliers."Whs" ----
  listWarehouses: async () => {
    const d = await sb.from('suppliers').select('name,Whs').eq('active', true).then(unwrap);
    const m = new Map();
    (d || []).forEach(s => { if (s.Whs && !m.has(s.Whs)) m.set(s.Whs, s.name); });
    return [...m].map(([code, name]) => ({ code, name })).sort((a, b) => a.code.localeCompare(b.code, undefined, { numeric: true }));
  },
  // peta nama pemasok -> kode warehouse
  supplierWhs: async () => Object.fromEntries(((await sb.from('suppliers').select('name,Whs').then(unwrap)) || []).map(s => [s.name, s.Whs || ''])),
  // isi cache warehouse untuk baris yang punya sku + batch (asal: Packing List -> pemasok -> Whs)
  whsEnsure: async (rows) => {
    try {
      const list = (rows || []).filter(r => r && r.sku && r.batch);
      const need = [...new Set(list.filter(r => !_bw.has(r.sku + '|' + r.batch)).map(r => r.batch))];
      if (!need.length) return;
      const sup = await api.supplierWhs();
      for (let i = 0; i < need.length; i += 100) {
        const d = await sb.from('packing_list_lines').select('sku,batch,packing_lists(supplier)').in('batch', need.slice(i, i + 100)).then(unwrap);
        (d || []).forEach(r => _bw.set(r.sku + '|' + r.batch, sup[r.packing_lists?.supplier] || ''));
      }
      list.forEach(r => { if (!_bw.has(r.sku + '|' + r.batch)) _bw.set(r.sku + '|' + r.batch, ''); });
    } catch (e) { /* gagal -> kolom Whs tampil '—' */ }
  },
  whsOf: (sku, batch) => _bw.get(sku + '|' + batch) || '—',

  // ---- label inbound ----
  listInboundLinesForLabel: (no) => sb.from('inbound_lines').select('*,products(name,pcs_per_ctn)').eq('doc_no', no).then(unwrap),
  profileNames: async (ids) => { try { if (!ids.length) return {}; const d = await sb.from('profiles').select('id,name').in('id', ids).then(unwrap); return Object.fromEntries((d || []).map(p => [p.id, p.name])); } catch (e) { return {}; } },
};
