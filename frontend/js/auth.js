// ============================================================
// AUTH — layar login & daftar, dan status "menunggu role".
// ============================================================
import { auth, api, appVersion } from './api.js';
import { $, v, inp, toast, esc } from './ui.js';

export let ME = null; // {id,email,name,role,active}

export async function loadMe(session) {
  const p = await api.myProfile(session.user.id);
  ME = { id: session.user.id, email: session.user.email, name: p?.name || session.user.email, role: p?.role || null, active: p?.active ?? true };
}

export function renderLogin(root, onReady, mode = 'in') {
  root.innerHTML = `<div class="lgn"><div class="lgc"><img class="lgl" src="img/logo.svg" alt="WMS"><h1>WMS FG Warehouse</h1><p>Serena Indopapangan — masuk untuk melanjutkan</p>
  <div id="lf">${inp('le', 'Email')}${inp('lp', 'Kata sandi', '', 'password')}<button class="btn" id="lgo" style="width:100%">${mode === 'in' ? 'Masuk' : 'Buat akun'}</button></div>
  <p class="l" style="text-align:center;margin-top:12px">${mode === 'in' ? `Belum punya akun? <a href="#" id="sw">Daftar</a>` : `Sudah punya akun? <a href="#" id="sw">Masuk</a>`}</p>
  ${mode === 'up' ? '<p class="note" style="margin-top:10px">Akun baru belum bisa mengakses data sampai role-nya diatur oleh admin.</p>' : ''}</div></div>`;
  appVersion().then(ver => { const c = root.querySelector('.lgc'); if (ver && c) c.insertAdjacentHTML('beforeend', `<p class="l" style="margin:14px 0 0;font-size:11px;opacity:.7">Versi ${esc(ver)}</p>`); });
  $('#sw').onclick = (e) => { e.preventDefault(); renderLogin(root, onReady, mode === 'in' ? 'up' : 'in'); };
  $('#lgo').onclick = async () => {
    const email = v('le').trim(), pw = v('lp');
    if (!email || !pw) return toast('Isi email dan kata sandi.');
    $('#lgo').disabled = true; $('#lgo').innerHTML = '<span class="spin"></span>';
    const r = mode === 'in' ? await auth.signIn(email, pw) : await auth.signUp(email, pw);
    if (r.error) { toast(r.error.message); $('#lgo').disabled = false; $('#lgo').textContent = mode === 'in' ? 'Masuk' : 'Buat akun'; return; }
    if (mode === 'up' && !r.data.session) { toast('Akun dibuat. Cek email untuk verifikasi, lalu masuk.'); renderLogin(root, onReady, 'in'); return; }
    onReady();
  };
}

export function renderPendingRole(root) {
  root.innerHTML = `<div class="lgn"><div class="lgc"><h1>Menunggu akses</h1><p>Akun <b>${esc(ME.email)}</b> sudah masuk tapi belum diberi role oleh admin gudang. Hubungi admin untuk diaktifkan.</p><button class="btn o" id="lo" style="width:100%">Keluar</button></div></div>`;
  $('#lo').onclick = () => auth.signOut();
}
