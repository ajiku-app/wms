#!/usr/bin/env bash
# ============================================================
# Kirim perubahan WMS ke GitHub (ajiku-app/wms) + rilis opsional.
#
#   bash rilis.sh "pesan commit"           -> commit + push ke main (tanpa rilis baru)
#   bash rilis.sh 2.0.14 "pesan commit"    -> commit + tag v2.0.14 + push
#                                             => GitHub Actions membangun installer Windows,
#                                                lalu semua PC menerima update otomatis.
#
# Perlu login GitHub (gh auth login / SSH key / Personal Access Token).
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

VER=""; MSG=""
if [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then VER="$1"; shift; fi
MSG="${1:-}"
[ -z "$MSG" ] && MSG="${VER:+v$VER}${VER:+ - }Update WMS"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || { echo "Anda di branch '$BRANCH'. Pindah dulu ke main: git checkout main"; exit 1; }

if [ -n "$VER" ]; then
  git rev-parse -q --verify "refs/tags/v$VER" >/dev/null && { echo "Tag v$VER sudah ada. Pakai nomor versi yang baru."; exit 1; }
  # samakan versi aplikasi desktop dengan nomor rilis (dipakai untuk auto-update)
  node -e "const fs=require('fs');const p='desktop/package.json';const j=JSON.parse(fs.readFileSync(p,'utf8'));j.version='$VER';fs.writeFileSync(p,JSON.stringify(j,null,2)+'\n')"
fi

git add -A
if git diff --cached --quiet; then echo "(tidak ada perubahan baru untuk di-commit)"; else git commit -m "$MSG"; fi

echo ">> Mengambil perubahan terbaru dari GitHub..."
git pull --rebase --autostash origin main

if [ -n "$VER" ]; then git tag -a "v$VER" -m "WMS v$VER"; fi

echo ">> Mengirim ke GitHub..."
git push origin main
[ -n "$VER" ] && git push origin "v$VER"

echo "Selesai."
[ -n "$VER" ] && echo "Build installer: https://github.com/ajiku-app/wms/actions  |  Rilis: https://github.com/ajiku-app/wms/releases"
exit 0
