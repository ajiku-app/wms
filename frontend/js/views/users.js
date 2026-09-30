import { api } from '../api.js';
import { $, hd, T, bar, ic, tag, sel, v, modal, toast, rpcErr, esc } from '../ui.js';

export async function renderUsers() {
  const data = await api.listProfiles();
  $('#main').innerHTML = hd('Users Management') +
    `<div class="note">Akun baru dibuat sendiri lewat halaman Daftar. Di sini admin memberi role agar akun bisa mengakses data.</div>
    <div class="card">${bar('')}${T(['Nama', 'Role', 'Status', 'Aksi'], data.map(u => `<tr><td>${esc(u.name)}</td><td>${u.role ? tag('open', u.role) : tag('exp', 'belum diatur')}</td><td>${tag(u.active, u.active ? 'Aktif' : 'Nonaktif')}</td><td>${ic('usRole', u.id, 'Atur role')} ${ic('usTg', u.id + '|' + (!u.active), u.active ? 'Nonaktifkan' : 'Aktifkan')}</td></tr>`))}</div>`;
}

export function registerUsersActions(A, go) {
  A.usRole = (u) => modal('Atur Role', sel('f_role', 'Role*', [['inbound', 'Inbound'], ['picker', 'Picker'], ['admin', 'Admin'], ['supervisor', 'Supervisor']]), 'Simpan', 'usRoleGo', u);
  A.usRoleGo = async (u) => {
    try { await api.setUserRole(u, v('f_role')); A.mx(); toast('Role diperbarui.'); go('users'); } catch (e) { rpcErr(e); }
  };
  A.usTg = async (s) => {
    const [u, act] = s.split('|');
    try { await api.setUserActive(u, act === 'true'); go('users'); } catch (e) { rpcErr(e); }
  };
}
