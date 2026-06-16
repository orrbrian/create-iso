@echo off
setlocal
rem Installs the "Create ISO from folder" right-click menu entry for the
rem current user. No admin rights required.

set "INSTALL_DIR=%LOCALAPPDATA%\CreateIso"
set "SCRIPT_NAME=New-IsoFromFolder.ps1"
set "LAUNCHER_NAME=Launch-Hidden.vbs"
set "SRC_PS1=%~dp0%SCRIPT_NAME%"
set "SRC_VBS=%~dp0%LAUNCHER_NAME%"
set "DST_PS1=%INSTALL_DIR%\%SCRIPT_NAME%"
set "DST_VBS=%INSTALL_DIR%\%LAUNCHER_NAME%"

if not exist "%SRC_PS1%" (
    echo [install] ERROR: cannot find %SRC_PS1%
    exit /b 1
)
if not exist "%SRC_VBS%" (
    echo [install] ERROR: cannot find %SRC_VBS%
    exit /b 1
)

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%" || (
    echo [install] ERROR: failed to create %INSTALL_DIR%
    exit /b 1
)

copy /Y "%SRC_PS1%" "%DST_PS1%" >nul || (
    echo [install] ERROR: failed to copy script to %DST_PS1%
    exit /b 1
)
copy /Y "%SRC_VBS%" "%DST_VBS%" >nul || (
    echo [install] ERROR: failed to copy launcher to %DST_VBS%
    exit /b 1
)

rem Launch via wscript.exe (GUI subsystem) so the PowerShell console never
rem flashes. The .vbs forwards the clicked folder path to the .ps1 and uses
rem SW_HIDE so nothing is shown except the WinForms progress dialog.
set "PS_CMD=wscript.exe \"%DST_VBS%\" \"%%V\""

rem Right-click on a folder (Directory)
reg add "HKCU\Software\Classes\Directory\shell\CreateIso" /ve /d "Create ISO from folder" /f >nul
reg add "HKCU\Software\Classes\Directory\shell\CreateIso" /v "Icon" /d "imageres.dll,-164" /f >nul
reg add "HKCU\Software\Classes\Directory\shell\CreateIso\command" /ve /d "%PS_CMD%" /f >nul

rem Right-click on the background of a folder (inside it)
reg add "HKCU\Software\Classes\Directory\Background\shell\CreateIso" /ve /d "Create ISO from this folder" /f >nul
reg add "HKCU\Software\Classes\Directory\Background\shell\CreateIso" /v "Icon" /d "imageres.dll,-164" /f >nul
reg add "HKCU\Software\Classes\Directory\Background\shell\CreateIso\command" /ve /d "%PS_CMD%" /f >nul

echo [install] Installed to %INSTALL_DIR%
echo [install] On Windows 11, right-click a folder then choose "Show more options"
echo [install] (or press Shift+F10) to see "Create ISO from folder".
endlocal
