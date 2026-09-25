@echo off
setlocal
if not exist "%~dp0hora-certa-windows.ps1" goto missing_script
where pwsh.exe >nul 2>&1
if not errorlevel 1 goto run_script
echo ERRO: PowerShell 7 nao encontrado.
where winget.exe >nul 2>&1
if errorlevel 1 goto missing_winget
set /p HC_INSTALAR="Instalar PowerShell 7 com winget agora? [s/N]: "
if /i not "%HC_INSTALAR%"=="s" exit /b 2
winget install --id Microsoft.PowerShell --exact --source winget --installer-type wix --scope machine --accept-package-agreements --accept-source-agreements
if errorlevel 1 exit /b 2
echo Instalado. Abra outro terminal como Administrador e execute este .bat novamente.
exit /b 2
:missing_winget
echo Consulte https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows
exit /b 2
:missing_script
echo ERRO: mantenha hora-certa.bat e hora-certa-windows.ps1 na mesma pasta.
exit /b 2
:run_script
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0hora-certa-windows.ps1" %*
exit /b %errorlevel%
