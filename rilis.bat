@echo off
rem Pakai:  rilis.bat "pesan"   atau   rilis.bat 2.0.14 "pesan"   (lihat rilis.sh)
set "GITBASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%GITBASH%" set "GITBASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not exist "%GITBASH%" (echo Git for Windows belum terpasang: https://git-scm.com/download/win & exit /b 1)
"%GITBASH%" "%~dp0rilis.sh" %*
