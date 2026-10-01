import { api } from '../api.js';
import { $, T, tag, fmt, v, iso, esc } from '../ui.js';

const TP = { GR: 'done', GI: 'open', MOVE: 'used', ADJ: 'near' };
// Saldo berjalan per SKU dari buku besar: GR +, GI −, ADJ ± (selisih), MOVE tidak mengubah total (tampil "–").
const delta = (m) => m.type === 'GR' ? m.qty : m.type === 'GI' ? -m.qty : m.type === 'ADJ' ? m.qty : 0;

function chart(pts) {
  if (pts.length < 2) return '<div class="empty">Belum cukup data untuk grafik.</div>';
  const W = 1000, H = 250, P = 16, mn = Math.min(0, ...pts), mx = Math.max(...pts), rg = mx - mn || 1;
  const xy = pts.map((s, i) => `${P + i * (W - 2 * P) / (pts.length - 1)},${H - P - (s - mn) / rg * (H - 2 * P)}`).join(' ');
  const z = H - P - (0 - mn) / rg * (H - 2 * P);
  return `<svg class="lc" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none"><line x1="0" x2="${W}" y1="${z}" y2="${z}"/><polyline points="${xy}"/></svg>`;
}

export async function renderKartu() {
  const prods = await api.listProducts();
  if (!prods.length) { $('#main').innerHTML = '<div class="card empty">Belum ada produk.</div>'; return; }
  let sku = window.__kSku && prods.some(p => p.sku === window.__kSku) ? window.__kSku : prods[0].sku;
  $('#main').innerHTML = `<div class="card"><label style="max-width:360px">Produk<select id="kp">${prods.map(p => `<option value="${esc(p.sku)}" ${p.sku === sku ? 'selected' : ''}>${esc(p.sku)} — ${esc(p.name)}</option>`).join('')}</select></label><div id="kb">Memuat…</div></div>`;
  const load = async () => {
    sku = window.__kSku = v('kp');
    const mv = await api.stockCard(sku); let s = 0;
    await api.whsEnsure(mv.map(m => ({ sku, batch: m.batch })));
    const rows = mv.map(m => { s += delta(m); return { ...m, d: delta(m), s }; });
    $('#kb').innerHTML = `<p class="l" style="margin:10px 0 0">Saldo sekarang: <b style="color:var(--ink)">${fmt(s)} ctn</b></p>${chart(rows.map(r => r.s))}
    ${T(['Tanggal', 'Tipe', 'Dokumen', 'Whs', 'Mutasi', 'Saldo'].map((h, i) => i > 3 ? `<span style="display:block;text-align:right">${esc(h)}</span>` : h),
      rows.map(r => `<tr><td>${iso(new Date(r.moved_at))}</td><td>${tag(TP[r.type] || 'used', r.type)}</td><td>${esc(r.doc_no || '—')}</td><td>${esc(api.whsOf(sku, r.batch))}</td><td class="num">${r.d === 0 ? '–' : (r.d > 0 ? '+' : '') + fmt(r.d)}</td><td class="num">${fmt(r.s)}</td></tr>`))}`;
  };
  $('#kp').onchange = load; await load();
}
