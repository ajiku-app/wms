import { api } from '../api.js';
import { $, fmt, toast, modal, bno, esc } from '../ui.js';
import { ME } from '../auth.js';

const qrP = new Promise((res) => {
  const s = document.createElement('script');
  s.src = 'https://cdnjs.cloudflare.com/ajax/libs/qrcode-generator/1.4.4/qrcode.min.js';
  s.onload = res; s.onerror = res; document.head.appendChild(s);
});
// QR code -> SVG (skala otomatis, tajam saat dicetak)
function qr(code) {
  try {
    if (window.qrcode) {
      const q = window.qrcode(0, 'M');
      q.addData(code); q.make();
      const n = q.getModuleCount(), m = 2; // quiet zone 2 modul
      let d = '';
      for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (q.isDark(r, c)) d += `M${c + m} ${r + m}h1v1h-1z`;
      const t = n + m * 2;
      return `<svg class="lbc" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${esc(t)} ${esc(t)}" shape-rendering="crispEdges"><rect width="${esc(t)}" height="${esc(t)}" fill="#fff"/><path d="${esc(d)}" fill="#000"/></svg>`;
    }
  } catch (e) {}
  return '';
}
const fullBatch = (b) => bno(b.sku, b.batch);
// nomor urut batch naik per pallet: ...20280310.001 -> .002 -> .003 (lebar digit dipertahankan)
const bumpBatch = (batch, k) => { const m = String(batch).match(/^(.*?)(\d+)$/); return m ? m[1] + String(parseInt(m[2], 10) + k - 1).padStart(m[2].length, '0') : batch; };
const oneLabel = (b) => `<div class="lb"><div class="lh"><span>Serena Indopapangan / Gudang FG</span><span>${esc(b.no)}</span></div>
<div class="lbody"><div class="linfo"><div><div class="ls">${esc(b.sku)}</div><div class="ln">${esc(b.nama || '')}</div></div>
<div class="lg"><div class="full"><small>Batch</small><b>${esc(fullBatch(b))}</b></div><div class="hi"><small>Kedaluwarsa (ED)</small>${esc(b.exp)}</div><div><small>Tgl produksi</small>${esc(b.prod || '—')}</div>
<div class="hi"><small>Rak tujuan</small>${esc(b.loc || '—')}</div><div><small>PIC</small>${esc(b.pic || '—')}</div></div></div>
<div class="lqr">${b.svg}<span class="qp">${b.pal ? esc('PALLET ' + b.pal) : 'SCAN QR'}</span><span class="qn${fmt(b.q).length > 4 ? ' qs' : ''}">${fmt(b.q)}</span><span class="qk">CTN</span></div></div></div>`;
// 9 label per lembar A4 (3 x 3)
const labelsHTML = (L) => { let h = ''; for (let i = 0; i < L.length; i += 9) h += `<div class="pg">${L.slice(i, i + 9).map(oneLabel).join('')}</div>`; return h; };

// ---- Dialog cetak label (pengganti prompt bawaan browser) ----
let LB = null, LP = '';
const perOf = (i) => Math.max(0, parseInt(document.getElementById('lp' + i)?.value, 10) || 0);
const qtyOf = (x) => x.qty_received || x.qty_pl;
const plan = (q, per) => { if (!per || q <= per) return { n: 1, last: q, per: q }; const n = Math.ceil(q / per); return { n, last: q - per * (n - 1), per }; };

function lblPrev() {
  if (!LB) return;
  let total = 0;
  LB.lines.forEach((x, i) => {
    const p = plan(qtyOf(x), perOf(i)); total += p.n;
    const t = p.n === 1 ? '1 label (' + fmt(qtyOf(x)) + ' ctn)' : (p.last === p.per ? p.n + ' label × ' + fmt(p.per) + ' ctn' : p.n + ' label (' + (p.n - 1) + ' × ' + fmt(p.per) + ' ctn + 1 × ' + fmt(p.last) + ' ctn)');
    const el = document.getElementById('lv' + i); if (el) el.textContent = '→ ' + t;
  });
  const el = document.getElementById('lpt'); if (el) el.textContent = 'Total ' + total + ' label · ' + Math.ceil(total / 9) + ' lembar A4';
}

export function registerLabelActions(A) {
  A.lbl = async (no) => {
    await qrP;
    const lines = (await api.listInboundLinesForLabel(no)).filter(x => qtyOf(x) > 0);
    if (!lines.length) return toast('Belum ada item untuk dicetak.');
    const names = await api.profileNames([...new Set(lines.map(x => x.pic).filter(Boolean))]);
    lines.sort((a, b) => String(a.sku).localeCompare(String(b.sku)) || String(a.batch).localeCompare(String(b.batch)));
    LB = { no, lines, names };
    const def = () => '0'; // tiap batch sudah = 1 pallet (dipecah di Packing List)
    const body = '<div class="lpm">' + lines.map((x, i) => `<div class="lpr"><div class="lpi"><b>${esc(x.sku)}</b><span>${esc(x.products?.name || '')}</span><small>Batch ${esc(bno(x.sku, x.batch))} · Total ${fmt(qtyOf(x))} ctn</small></div><div class="lpv" id="lv${i}"></div></div>`).join('')
      + '<p class="lpt" id="lpt"></p><p class="l" style="margin:0">Satu label = satu pallet = satu batch. Pallet dipecah di Packing List, bukan saat cetak label, supaya tidak ada label ganda.</p></div>';
    modal('Cetak Label — ' + no, body, 'Cetak Label', 'lblGo', no);
    $('#mod').oninput = lblPrev; lblPrev();
  };
  A.lblGo = () => {
    if (!LB) return;
    const { no, lines, names } = LB, L = [];
    lines.forEach((x, i) => {
      const per = perOf(i), q = qtyOf(x);
      const ppc = x.products?.pcs_per_ctn || 1;
      const pic = names[x.pic] || ME?.name || '';
      const base = { sku: x.sku, nama: x.products?.name, batch: x.batch, prod: x.production_date, exp: x.expiry, loc: x.rack_code, pic, no };
      if (!per || q <= per) {
        // satu batch = satu pallet: nomor pallet diambil dari urutan batch (SKU + ED yang sama) di dokumen ini
        const grp = lines.filter(z => z.sku === x.sku && String(z.batch).split('.')[0] === String(x.batch).split('.')[0]);
        const pal = grp.length > 1 ? String(grp.indexOf(x) + 1).padStart(3, '0') + '/' + String(grp.length).padStart(3, '0') : undefined;
        L.push({ ...base, q, pcs: q * ppc, pal, svg: qr(x.sku + '|' + x.batch) }); return;
      }
      const n = Math.ceil(q / per);
      for (let k = 1; k <= n; k++) {
        const qq = k < n ? per : q - per * (n - 1);
        const no3 = String(k).padStart(3, '0');
        L.push({ ...base, batch: bumpBatch(x.batch, k), q: qq, pcs: qq * ppc, pal: no3 + '/' + String(n).padStart(3, '0'), svg: qr(x.sku + '|' + x.batch + '|' + no3) });
      }
    });
    LB = null; LP = labelsHTML(L);
    modal('Pratinjau Label — ' + no, `<p class="l" style="margin:0 0 8px">${L.length} label · ${Math.ceil(L.length / 9)} lembar A4 (landscape). Periksa dulu, lalu klik Cetak.</p><div class="pvw"><div class="pvz">${LP}</div></div>`, 'Cetak', 'lblPrint', '', '', 'wide');
  };
  A.lblPrint = () => {
    if (!LP) return;
    $('#lbl').innerHTML = LP;
    window.addEventListener('afterprint', () => { $('#lbl').innerHTML = ''; }, { once: true });
    setTimeout(() => { try { window.print(); } catch (e) { toast('Cetak diblokir browser.'); } }, 50);
  };
}
