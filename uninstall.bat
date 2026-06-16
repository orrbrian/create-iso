@echo off
setlocal
set "INSTALL_DIR=%LOCALAPPDATA%\CreateIso"

reg delete "HKCU\Software\Classes\Directory\shell\CreateIso" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Directory\Background\shell\CreateIso" /f >nul 2>&1

if exist "%INSTALL_DIR%" rmdir /S /Q "%INSTALL_DIR%"

echo [uninstall] Removed "Create ISO" context menu entry and %INSTALL_DIR%.
endlocal
