// ============================================================
// UI HELPERS — potongan HTML/format yang dipakai berulang di
// semua halaman. Tidak ada logika bisnis atau panggilan API di
// sini, murni presentasi.
// ============================================================
export const $ = (s) => document.querySelector(s);
// ===== Keamanan: semua data dari database/pengguna WAJIB lewat esc() sebelum masuk ke innerHTML =====
const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ESC[c]);
// Sel CSV: cegah formula injection (=, +, -, @) saat file dibuka di Excel; angka murni tidak diubah
export const csvCell = (c) => { let t = String(c ?? ''); if (/^[=+\-@\t\r]/.test(t) && !/^-?\d+([.,]\d+)?$/.test(t)) t = "'" + t; return '"' + t.replace(/"/g, '""') + '"'; };
export const today = new Date(); today.setHours(0, 0, 0, 0);
export const iso = (d) => new Date(d.getTime() - d.getTimezoneOffset() * 6e4).toISOString().slice(0, 10);
export const TD = iso(today);
export const YMD = TD.replace(/-/g, '');
export const days = (s) => (s ? Math.round((new Date(s + 'T00:00') - today) / 864e5) : null);
export const fmt = (n) => Number(n || 0).toLocaleString('id-ID');
export const est = (e) => { if (!e) return ['near', '—']; const d = days(e); return d < 0 ? ['exp', 'Kedaluwarsa'] : d <= 90 ? ['near', '≤ 90 hari'] : ['Aman', 'Aman']; };
export const tag = (c, t) => `<span class="tag t-${esc(c)}">${esc(t || c)}</span>`;
export const v = (id) => { const e = document.getElementById(id); return e ? e.value : ''; };
export const inp = (id, l, val = '', t = 'text') => `<label>${esc(l)}<input id="${esc(id)}" type="${esc(t)}" value="${esc(val)}"></label>`;
export const sel = (id, l, o) => `<label>${esc(l)}<select id="${esc(id)}">${o.map(x => `<option value="${esc(x[0])}">${esc(x[1])}</option>`).join('')}</select></label>`;
export const T = (cols, rows) => `<div class="wrap" data-pg><table><thead><tr>${cols.map(c => `<th>${c}</th>`).join('')}</tr></thead><tbody>${rows.length ? rows.join('') : `<tr><td colspan="${cols.length}" class="empty">Data Tidak Ditemukan</td></tr>`}</tbody></table></div><div class="pgr"></div>`;
// Prefix batch dari SKU: FGKGPA.0001 -> FGKGPA.001 (angka 3 digit). Batch di database tetap pendek (20280310.001);
// prefix hanya ditampilkan di layar & label -> FGKGPA.001.20280310.001
export const skuPrefix = (sku) => { const [a, n] = String(sku || '').split('.'); return (n !== undefined && /^\d+$/.test(n)) ? a + '.' + String(parseInt(n, 10)).padStart(3, '0') : String(sku || ''); };
export const bno = (sku, batch) => { const pf = skuPrefix(sku); return !sku || String(batch).startsWith(pf + '.') ? String(batch) : pf + '.' + batch; };
export const hd = (t, x = '') => (x ? `<div class="hd">${x}</div>` : ''); // judul halaman ada di top bar
export const ic = (a, val, t, c = 'o') => `<button class="btn ${esc(c)} s" data-a="${esc(a)}" data-v="${esc(val)}">${t}</button>`;
export const bt = (a, t, val = '') => `<button class="btn" data-a="${esc(a)}" data-v="${esc(val)}">${t}</button>`;
export const srch = '<input class="sr" placeholder="Cari..." aria-label="Cari">';
document.addEventListener('input', (e) => {
  const el = e.target, card = el.classList && el.classList.contains('sr') && el.closest('.card'); if (!card) return;
  card.querySelectorAll('.wrap[data-pg]').forEach(w => { w._q = el.value; w._page = 1; pgRefresh(w); });
});
export const bar = (b) => `<div class="ch">${srch}${b}</div>`;
export const nextNo = (p, n) => `${p}-${YMD}-${String(n + 1).padStart(3, '0')}`;

export function toast(m) {
  const t = $('#toast'); t.textContent = m; t.className = 'toast s';
  setTimeout(() => t.className = 'toast', 2800);
}
export function rpcErr(e) {
  const m = (e && e.message) || 'Terjadi kesalahan';
  toast(m.replace(/^.*ERROR:\s*/, ''));
}
export function modal(t, body, ok, act, val, ex = '', w = '') {
  $('#mod').innerHTML = `<div class="ov"><div class="md ${esc(w)}" role="dialog" aria-label="${esc(t)}"><div class="mh"><b>${esc(t)}</b><button data-a="mx">✕</button></div>${body}<div class="mf"><button class="btn o" data-a="mx">Batal</button>${ex}${ok ? bt(act, ok, val) : ''}</div></div></div>`;
}

/** Cari nomor dokumen baru yang belum terpakai, mengulang jika bentrok. */
export async function findFreeNo(prefix, table, api) {
  const { count } = await ({
    packing_lists: api.countPackingLists, inbound_docs: api.countInboundDocs,
    outbound_docs: api.countOutboundDocs, opname_docs: api.countOpnameDocs,
  })[table]();
  let n = 0, no = nextNo(prefix, count || 0);
  while (await api.docExists(table, no)) { n++; no = nextNo(prefix, (count || 0) + n); }
  return no;
}


// ===== Pagination: 10 baris per halaman untuk semua tabel (T) + pencarian lintas halaman =====
export const PAGE_SIZE = 10;
export function pgRefresh(w) {
  const rows = [...w.querySelectorAll('tbody tr')].filter(r => !r.querySelector('td.empty'));
  const q = (w._q || '').toLowerCase();
  const m = [];
  rows.forEach(r => { r._m = !q || r.textContent.toLowerCase().includes(q); if (r._m) m.push(r); });
  const pages = Math.max(1, Math.ceil(m.length / PAGE_SIZE));
  w._page = Math.min(Math.max(1, w._page || 1), pages);
  const a = (w._page - 1) * PAGE_SIZE, b = a + PAGE_SIZE;
  let k = 0;
  rows.forEach(r => { if (r._m) { r.style.display = (k >= a && k < b) ? '' : 'none'; k++; } else r.style.display = 'none'; });
  const bar = w.nextElementSibling;
  if (!bar || !bar.classList.contains('pgr')) return;
  if (m.length <= PAGE_SIZE) { bar.innerHTML = ''; return; }
  const cur = w._page, set = new Set([1, pages, cur - 1, cur, cur + 1]);
  const nums = [...set].filter(n => n >= 1 && n <= pages).sort((x, y) => x - y);
  let btns = '', prev = 0;
  nums.forEach(n => { if (n - prev > 1) btns += '<span class="pe">…</span>'; btns += `<button data-p="${n}" class="${n === cur ? 'on' : ''}">${n}</button>`; prev = n; });
  bar.innerHTML = `<span>Menampilkan ${a + 1}–${Math.min(b, m.length)} dari ${fmt(m.length)}</span><span class="pb"><button data-p="${cur - 1}" ${cur === 1 ? 'disabled' : ''}>‹</button>${btns}<button data-p="${cur + 1}" ${cur === pages ? 'disabled' : ''}>›</button></span>`;
}
document.addEventListener('click', (e) => {
  const b = e.target.closest('.pgr button[data-p]'); if (!b || b.disabled) return;
  const w = b.closest('.pgr').previousElementSibling; if (!w) return;
  w._page = +b.dataset.p; pgRefresh(w);
});
// Tabel baru (hasil render apa pun) otomatis dipasangi pager
new MutationObserver(() => {
  document.querySelectorAll('.wrap[data-pg]:not([data-pgi])').forEach(w => {
    w.dataset.pgi = '1';
    const sr = w.closest('.card')?.querySelector('.sr'); if (sr && sr.value) w._q = sr.value;
    pgRefresh(w);
  });
}).observe(document.body, { childList: true, subtree: true });


// ===== Dialog konfirmasi / input teks (pengganti confirm() & prompt() bawaan browser) =====
function dialog({ title, body, ok, focusSel }) {
  return new Promise((resolve) => {
    document.getElementById('dlg')?.remove();
    const d = document.createElement('div'); d.id = 'dlg';
    d.innerHTML = `<div class="ov"><div class="md dlgm" role="dialog" aria-modal="true" aria-label="${esc(title)}"><div class="mh"><b>${esc(title)}</b><button data-x>✕</button></div>${body}<div class="mf"><button class="btn o" data-x>Batal</button><button class="btn" data-ok>${ok}</button></div></div></div>`;
    document.body.appendChild(d);
    const done = (val) => { d.remove(); document.removeEventListener('keydown', key, true); resolve(val); };
    const okv = () => done(focusSel ? d.querySelector(focusSel).value.trim() : true);
    const no = () => done(focusSel ? null : false);
    function key(e) { if (e.key === 'Escape') { e.preventDefault(); no(); } else if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); okv(); } }
    d.addEventListener('click', (e) => { if (e.target.closest('[data-ok]')) okv(); else if (e.target.closest('[data-x]') || e.target.classList.contains('ov')) no(); });
    document.addEventListener('keydown', key, true);
    setTimeout(() => (focusSel ? d.querySelector(focusSel) : d.querySelector('[data-ok]'))?.focus(), 30);
  });
}
/** Konfirmasi ya/tidak -> Promise<boolean> */
export const askConfirm = (title, message, ok = 'Ya, lanjutkan') => dialog({ title, body: `<p class="dlgp">${esc(message)}</p>`, ok });
/** Input satu baris -> Promise<string|null> (null = dibatalkan, '' = kosong) */
export const askText = (title, label, ok = 'Simpan', ph = '') => dialog({ title, body: `<label>${esc(label)}<input id="dlgIn" type="text" placeholder="${esc(ph)}" autocomplete="off"></label>`, ok, focusSel: '#dlgIn' });
