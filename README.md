# Gudang FG — Serena Indopapangan

Struktur tiga lapis: **frontend**, **backend**, dan **API** yang
menghubungkan keduanya.

```
frontend/     halaman web statis (HTML/CSS/JS modular) — dijalankan di browser
backend/      skema database, keamanan (RLS), dan logika bisnis — Supabase Postgres
API.md        kontrak antara frontend dan backend (endpoint REST + RPC)
```

## frontend/
```
frontend/
├── index.html            shell HTML, memuat css + js/app-entry.js
├── css/style.css          seluruh gaya visual
└── js/
    ├── config.js           alamat & kunci publik Supabase (satu-satunya tempat ini disimpan)
    ├── api.js              LAPISAN API — satu-satunya file yang memanggil backend
    ├── ui.js               komponen tampilan & format yang dipakai berulang
    ├── auth.js             layar masuk / daftar / menunggu role
    ├── app.js               shell aplikasi: sidebar, router antar halaman
    ├── app-entry.js         titik masuk (dipanggil dari index.html)
    └── views/                satu file per halaman (dashboard, inbound, outbound, dst.)
```
Aturan: `views/*.js` **tidak pernah** memanggil Supabase langsung — selalu
lewat `api.xxx()` dari `api.js`. Ini membuat frontend tidak peduli backend-nya
Supabase atau server lain, selama `api.js` mengembalikan bentuk data yang sama.

## backend/
Backend aplikasi ini adalah project Supabase (Postgres terkelola + Auth +
REST API otomatis + Row Level Security), bukan server Node terpisah. Isi
folder ini adalah salinan persis dari apa yang berjalan di project Supabase
`wms`, dibagi tiga:
- `schema.sql` — struktur tabel
- `policies.sql` — siapa boleh membaca apa
- `functions.sql` — logika bisnis (satu-satunya jalan mengubah data)

Detail lebih lanjut ada di `backend/README.md`.

## Menjalankan frontend

**Penting:** `frontend/js/app.js` memakai ES module (`import`/`export`)
dengan path relatif. Browser modern memblokir ini lewat `file://` (klik dua
kali membuka file) karena kebijakan CORS pada module script. Frontend harus
dijalankan lewat server, walau server sangat sederhana:

```bash
cd frontend
npx serve .          # atau: python3 -m http.server 8080
```
lalu buka `http://localhost:3000` (atau port yang ditampilkan).

Untuk pemakaian sehari-hari di gudang, unggah folder `frontend/` ke hosting
statis (Netlify, Vercel, Cloudflare Pages) atau ke server intranet gudang.

## Login pertama

Belum ada satu pun akun di database ini. Buka aplikasi → **Daftar** dengan
email & kata sandi Anda → beri tahu admin (atau jalankan SQL berikut sekali
lewat SQL Editor Supabase, ganti email) untuk menjadi admin pertama:

```sql
update public.profiles set role = 'admin', active = true
where id = (select id from auth.users where email = 'email_anda@contoh.com');
```

Setelah itu, pengguna berikutnya cukup diatur lewat menu **Manajemen
Pengguna** di aplikasi.

## Memasang di Windows

Ada dua cara; keduanya tetap memakai backend Supabase yang sama (perlu internet).

**A. Install dari browser (PWA) — tanpa build.** Setelah frontend di-hosting
(HTTPS atau `localhost`), buka di Edge/Chrome → ikon **Install** di address
bar (atau menu ⋯ → *Apps → Install this site as an app*). Aplikasi muncul di
Start Menu & desktop dengan jendela sendiri.

**B. Installer .exe (Electron).** Di PC Windows dengan Node.js terpasang:
```bat
cd desktop
build-windows.bat
```
Hasil: `desktop\dist\WMS FG Warehouse Setup 2.0.0.exe`. Untuk mencoba tanpa
membangun installer: `cd desktop && npm install && npm start`.

## Auto-update & rilis (GitHub: ajiku-app/wms)

Aplikasi desktop mengecek GitHub Releases saat dibuka (dan tiap 4 jam),
mengunduh versi baru di latar belakang, lalu menawarkan restart.

Merilis versi baru:
1. Ubah kode, naikkan `"version"` di `desktop/package.json` (mis. `2.0.2`).
2. `git add . && git commit -m "v2.0.2" && git tag v2.0.2 && git push && git push --tags`
3. GitHub Actions (`.github/workflows/release.yml`) membangun & mengunggah installer.
   Dalam beberapa menit semua PC yang membuka aplikasi akan menerima pembaruan.

Catatan: repo harus **publik** agar aplikasi bisa mengunduh pembaruan tanpa token.
Versi pertama yang berisi fitur ini (2.0.1) harus dipasang manual sekali.

## Kirim ke GitHub & rilis otomatis

Dari folder repo (Git Bash, atau `rilis.bat` di Windows):

```bash
bash rilis.sh "pesan commit"          # hanya commit + push ke main
bash rilis.sh 2.0.13 "pesan commit"   # commit + tag v2.0.13 + push -> installer Windows dibangun
                                      # & PC yang sudah terpasang menerima update otomatis
```
`ci.yml` memeriksa sintaks JS di setiap push/PR dan memastikan tag = versi `desktop/package.json`.
Migrasi database (`backend/migrate_*.sql`) **tidak** otomatis: jalankan manual di Supabase SQL Editor (backup dulu).
