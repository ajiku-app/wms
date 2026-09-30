import { api } from '../api.js';
import { $, v, toast, esc } from '../ui.js';

// Cetak label rak DIPERTAHANKAN: kode rak tetap format zona-bim-level (mis. A-01-03), sama dengan yang dibaca aplikasi scan.
const jsbP = new Promise((res) => {
  const s = document.createElement('script');
  s.src = 'https://cdnjs.cloudflare.com/ajax/libs/jsbarcode/3.11.6/JsBarcode.all.min.js';
  s.onload = res; s.onerror = res; document.head.appendChild(s);
});
const ARROW = {
  up: '<svg viewBox="0 0 24 32"><polygon points="12,0 24,14 16,14 16,32 8,32 8,14 0,14"/></svg>',
  down: '<svg viewBox="0 0 24 32"><polygon points="12,32 24,18 16,18 16,0 8,0 8,18 0,18"/></svg>',
};
function bc(code) {
  try {
    const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    window.JsBarcode(s, code, { format: 'CODE128', height: 45, width: 2, displayValue: false, margin: 0 });
    s.setAttribute('viewBox', `0 0 ${parseFloat(s.getAttribute('width'))} ${parseFloat(s.getAttribute('height'))}`);
    s.setAttribute('preserveAspectRatio', 'none'); s.removeAttribute('width'); s.removeAttribute('height');
    return s.outerHTML;
  } catch (e) { return ''; }
}
const label = (code, sub, dir) => `<div class="rk"><div class="rk-t"><div class="rk-c">${esc(code)}</div>${dir ? `<div class="rk-a">${ARROW[dir]}</div>` : ''}</div><div class="rk-s">${esc(sub)}</div><div class="rk-b">${bc(code)}</div></div>`;

let RACKS = [];
const items = () => {
  const L = v('rkL'), a = +v('rkA') || 1, b = +v('rkB') || a;
  return RACKS.map(r => { const m = /^([A-Z]+)-(\d+)-(\d+)$/.exec(r.code); return m && m[1] === L && +m[2] >= a && +m[2] <= b ? { code: r.code, L, bim: +m[2], lv: +m[3] } : null; })
    .filter(Boolean).sort((x, y) => x.bim - y.bim || x.lv - y.lv);
};
const html = (it) => it.map(x => label(x.code, `Rak ${x.L} · Bim ${x.bim} · Level ${x.lv}`, x.lv === 1 ? 'down' : 'up')).join('');

export async function renderRackLabel() {
  RACKS = await api.listRacks();
  const zones = [...new Set(RACKS.map(r => (/^([A-Z]+)-\d+-\d+$/.exec(r.code) || [])[1]).filter(Boolean))].sort();
  $('#main').innerHTML = `<div class="note">Cetak label rak tetap seperti sekarang. Kode rak memakai format zona-bim-level, sama dengan yang dibaca aplikasi scan.</div>
  <div class="card"><div class="flt"><label style="flex:0 1 90px">Zona<select id="rkL">${zones.map(z => `<option>${z}</option>`).join('')}</select></label>
  <label style="flex:0 1 130px">Bim dari<input id="rkA" type="number" min="1" value="1"></label><label style="flex:0 1 130px">Bim sampai<input id="rkB" type="number" min="1" value="2"></label>
  <button class="btn" data-a="rkPrint">Cetak label</button><button class="btn o" data-a="rkArea">Cetak label area</button><span class="l" id="rkN"></span></div><div class="rkg" id="rkP"></div></div>`;
  await jsbP;
  const pv = () => { const it = items(); $('#rkN').textContent = it.length + ' label'; $('#rkP').innerHTML = html(it); };
  ['rkL', 'rkA', 'rkB'].forEach(id => { $('#' + id).oninput = pv; }); pv();
}

export function registerRackLabelActions(A) {
  const printHTML = async (h) => {
    await jsbP;
    if (!h) return toast('Tidak ada rak untuk dicetak.');
    $('#lbl').innerHTML = `<div class="rkpg">${h}</div>`;
    window.addEventListener('afterprint', () => { $('#lbl').innerHTML = ''; }, { once: true });
    try { window.print(); } catch (e) { toast('Cetak diblokir browser.'); }
  };
  A.rkPrint = () => printHTML(html(items()));
  A.rkArea = () => printHTML(label('NON-RACK', 'Area non racking', null) + label('GR-STAGING', 'Area transit barang masuk', null));
}
