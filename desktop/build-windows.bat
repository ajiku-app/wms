@echo off
REM Membuat installer Windows (.exe). Jalankan di PC Windows yang terhubung internet.
REM Prasyarat: Node.js LTS (https://nodejs.org)
cd /d "%~dp0"
call npm install
if errorlevel 1 goto :err
call npm run dist
if errorlevel 1 goto :err
echo.
echo Selesai. Installer ada di folder: desktop\dist\
pause
exit /b 0
:err
echo Gagal. Periksa pesan error di atas.
pause
exit /b 1
