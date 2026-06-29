@rem © 2026 Jshaun Hookumchand. All rights reserved.
@echo off
if /i "%~1" NEQ "__keep" (
  start "Hook's - Generate & Build Tool" cmd /k ""%~f0" __keep"
  exit /b
)
setlocal enabledelayedexpansion

set "THIS_DIR=%~dp0"
pushd "%THIS_DIR%" >nul

REM -----------------------------
REM Script version + update source
REM (edit UPDATE_URL to point at any HTTPS-served copy of this file)
REM -----------------------------
set "SCRIPT_VERSION=4.0.0"
set "UPDATE_URL=https://raw.githubusercontent.com/hookc123/GenerateAndBuild/main/GenerateAndBuild.bat"

REM -----------------------------
REM Check for a newer version (silent on failure: offline, timeout, etc.)
REM -----------------------------
set "REMOTE_BAT=%TEMP%\GenerateAndBuild.remote.bat"
set "REMOTE_VERSION="

where curl >nul 2>&1
if errorlevel 1 goto :update_skip

curl -sSL --max-time 5 "%UPDATE_URL%" -o "%REMOTE_BAT%" >nul 2>&1
if not exist "%REMOTE_BAT%" goto :update_skip

for /f "usebackq tokens=2 delims==" %%V in (`findstr /r "SCRIPT_VERSION=[0-9]" "%REMOTE_BAT%"`) do set "REMOTE_VERSION=%%V"
if defined REMOTE_VERSION set "REMOTE_VERSION=!REMOTE_VERSION:~0,-1!"

if not defined REMOTE_VERSION goto :update_skip

REM -- Numeric compare of major.minor.patch. Only prompt if remote is strictly newer.
for /f "tokens=1,2,3 delims=." %%A in ("%SCRIPT_VERSION%") do (
    set "L_MAJ=%%A"
    set "L_MIN=%%B"
    set "L_PAT=%%C"
)
for /f "tokens=1,2,3 delims=." %%A in ("!REMOTE_VERSION!") do (
    set "R_MAJ=%%A"
    set "R_MIN=%%B"
    set "R_PAT=%%C"
)
if not defined L_MAJ set "L_MAJ=0"
if not defined L_MIN set "L_MIN=0"
if not defined L_PAT set "L_PAT=0"
if not defined R_MAJ set "R_MAJ=0"
if not defined R_MIN set "R_MIN=0"
if not defined R_PAT set "R_PAT=0"

if !R_MAJ! LSS !L_MAJ! goto :update_skip
if !R_MAJ! GTR !L_MAJ! goto :update_prompt
if !R_MIN! LSS !L_MIN! goto :update_skip
if !R_MIN! GTR !L_MIN! goto :update_prompt
if !R_PAT! LSS !L_PAT! goto :update_skip
if !R_PAT! GTR !L_PAT! goto :update_prompt
goto :update_skip

:update_prompt
echo.
echo ==============================================
echo   UPDATE AVAILABLE
echo ==============================================
echo.
echo   Current : %SCRIPT_VERSION%
echo   Latest  : !REMOTE_VERSION!
echo.
set /p "DO_UPDATE=Update now? [Y/n]: "
if /i "!DO_UPDATE!" NEQ "n" goto :update_apply

:update_skip
if exist "%REMOTE_BAT%" del "%REMOTE_BAT%" >nul 2>&1
goto :update_done

:update_apply
set "NEW_BAT=%~dp0GenerateAndBuild.bat.new"
move /y "%REMOTE_BAT%" "%NEW_BAT%" >nul
if not exist "%NEW_BAT%" (
    echo [WARN] Failed to stage update. Continuing with current version.
    goto :update_done
)

set "UPDATER=%TEMP%\GenerateAndBuild_update.cmd"
REM Clear the read-only attribute first: this script usually lives inside a
REM source-controlled Unreal project (Perforce), so %~f0 is read-only and
REM the self-replacing move/y would fail with access-denied every time.
> "%UPDATER%" (
    echo @echo off
    echo timeout /t 1 /nobreak ^>nul
    echo attrib -r "%~f0" ^>nul 2^>^&1
    echo move /y "%NEW_BAT%" "%~f0" ^>nul 2^>^&1
    echo if not errorlevel 1 goto moved
    echo timeout /t 2 /nobreak ^>nul
    echo move /y "%NEW_BAT%" "%~f0" ^>nul 2^>^&1
    echo if not errorlevel 1 goto moved
    echo timeout /t 3 /nobreak ^>nul
    echo move /y "%NEW_BAT%" "%~f0" ^>nul
    echo if errorlevel 1 ^(
    echo   echo [ERROR] Could not replace script: file may be locked.
    echo   pause
    echo   exit /b 1
    echo ^)
    echo :moved
    echo start "" "%~f0" __keep
    echo ^(goto^) 2^>nul ^& del "%%~f0"
)

echo [INFO] Updating to !REMOTE_VERSION! and relaunching...
start "" /b cmd /c "%UPDATER%"
popd >nul
exit

:update_done

REM -----------------------------
REM Find exactly one .uproject
REM -----------------------------
set "UPROJECT="
set /a COUNT=0
for %%F in (*.uproject) do (
    set /a COUNT+=1
    if !COUNT! EQU 1 set "UPROJECT=%%~fF"
)

if %COUNT% EQU 0 (
    echo [ERROR] No .uproject found in: "%THIS_DIR%"
    pause
    popd >nul
    exit /b 1
)

if %COUNT% GTR 1 (
    echo [ERROR] More than one .uproject found in: "%THIS_DIR%"
    dir /b *.uproject
    pause
    popd >nul
    exit /b 1
)

for %%F in ("%UPROJECT%") do set "PROJECT_NAME=%%~nF"

REM ---- SET P4IGNORE ----
setx P4IGNORE .p4ignore
echo [INFO] P4IGNORE set to .p4ignore
echo [INFO] Project : "%UPROJECT%"

REM -----------------------------
REM Preflight: detect VS 2022 + C++ workload + Windows SDK
REM -----------------------------
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "HAS_VS=0"
set "HAS_SDK=0"
set "VS_DISPLAY_NAME="
set "SDK_VERSION="

REM -- Check for VS 2017+ with C++ build tools via vswhere
REM    -products *      : include Build Tools (excluded by default)
REM    -version [15.0,) : VS 2017 or newer (UE 4.22+ needs VS 2017; UE 4.25+ needs VS 2019; UE 5.2+ needs VS 2022)
if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%I in (`"%VSWHERE%" -products * -version [15.0^,^) -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property displayName 2^>nul`) do (
        set "HAS_VS=1"
        set "VS_DISPLAY_NAME=%%I"
    )
)

REM -- Fallback: filesystem probe for VS versions vswhere can't detect (e.g. VS 2026)
if "!HAS_VS!"=="0" (
    for %%R in ("%ProgramFiles%\Microsoft Visual Studio" "%ProgramFiles(x86)%\Microsoft Visual Studio") do (
        if "!HAS_VS!"=="0" if exist %%R (
            for /f "delims=" %%V in ('dir /b /ad %%R 2^>nul') do (
                if "!HAS_VS!"=="0" (
                    for %%E in (Community Professional Enterprise BuildTools) do (
                        if "!HAS_VS!"=="0" if exist "%%~R\%%V\%%E\VC\Tools\MSVC\" (
                            set "HAS_VS=1"
                            set "VS_DISPLAY_NAME=Visual Studio %%V %%E [filesystem probe]"
                        )
                    )
                )
            )
        )
    )
)

REM -- Check for Windows 10/11 SDK via registry (robust: strip trailing backslash, no version filter)
set "KITS_ROOT="
for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows Kits\Installed Roots" /v KitsRoot10 2^>nul') do (
    if /i "%%A"=="REG_SZ" set "KITS_ROOT=%%B"
)
if defined KITS_ROOT (
    if "!KITS_ROOT:~-1!"=="\" set "KITS_ROOT=!KITS_ROOT:~0,-1!"
    for /f "delims=" %%V in ('dir /b /ad /on "!KITS_ROOT!\Include" 2^>nul') do (
        if exist "!KITS_ROOT!\Include\%%V\um\Windows.h" (
            set "HAS_SDK=1"
            set "SDK_VERSION=%%V"
        )
    )
)

if "!HAS_VS!"=="1" (
    echo [OK] Found: !VS_DISPLAY_NAME!
) else (
    echo [MISSING] Visual Studio 2022 with C++ workload not found.
)

if "!HAS_SDK!"=="1" (
    echo [OK] Found: Windows SDK !SDK_VERSION!
) else (
    echo [MISSING] Windows 10/11 SDK not found.
)

REM -- OS-aware SDK picker (Win10 -> 22621, Win11 -> 26100)
REM    WIN_SDK_COMPONENT is the matching VS Installer component ID (used as install fallback)
set "WIN_SDK_PKG=Microsoft.WindowsSDK.10.0.22621"
set "WIN_SDK_LABEL=Windows 10 SDK (10.0.22621)"
set "WIN_SDK_COMPONENT=Microsoft.VisualStudio.Component.Windows11SDK.22621"
for /f "tokens=4 delims=. " %%B in ('ver 2^>nul') do set "WIN_BUILD=%%B"
if defined WIN_BUILD if !WIN_BUILD! GEQ 22000 (
    set "WIN_SDK_PKG=Microsoft.WindowsSDK.10.0.26100"
    set "WIN_SDK_LABEL=Windows 11 SDK (10.0.26100)"
    set "WIN_SDK_COMPONENT=Microsoft.VisualStudio.Component.Windows11SDK.26100"
)

if "!HAS_VS!"=="0" if "!HAS_SDK!"=="0" (
    echo.
    echo ==============================================
    echo   MISSING: Visual Studio 2022 + Windows SDK
    echo ==============================================
    echo.
    echo Unreal Engine requires Visual Studio 2022 with
    echo the "Desktop development with C++" workload
    echo and a Windows SDK to generate project files and
    echo compile for Win64.
    echo.
    set /p "INSTALL_TOOLS=Install them now via winget? [Y/n]: "
    if /i "!INSTALL_TOOLS!" NEQ "n" (
        echo.
        echo [INFO] Installing VS 2022 Build Tools with C++ workload + !WIN_SDK_LABEL!...
        echo        This may take several minutes. An admin prompt may appear.
        echo.
        winget install Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --add !WIN_SDK_COMPONENT! --includeRecommended" --accept-source-agreements --accept-package-agreements
        if !ERRORLEVEL! NEQ 0 (
            echo.
            echo [ERROR] winget install failed. Please install Visual Studio 2022 manually
            echo         with the "Desktop development with C++" workload.
            pause
            popd >nul
            exit /b 1
        )
        echo.
        echo [OK] Installation complete. Continuing...
        echo.
    ) else (
        echo.
        echo [INFO] Skipped. Install Visual Studio 2022 with C++ workload manually, then re-run.
        pause
        popd >nul
        exit /b 1
    )
    goto :preflight_done
)

if "!HAS_VS!"=="0" (
    echo.
    echo ==============================================
    echo   MISSING: Visual Studio 2022 C++ Workload
    echo ==============================================
    echo.
    echo A Windows SDK was found ^(!SDK_VERSION!^), but Visual
    echo Studio 2022 with the "Desktop development with
    echo C++" workload is required.
    echo.
    set /p "INSTALL_VS=Install VS 2022 Build Tools now via winget? [Y/n]: "
    if /i "!INSTALL_VS!" NEQ "n" (
        echo.
        echo [INFO] Installing VS 2022 Build Tools with C++ workload...
        echo.
        winget install Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" --accept-source-agreements --accept-package-agreements
        if !ERRORLEVEL! NEQ 0 (
            echo.
            echo [ERROR] winget install failed. Install Visual Studio 2022 manually.
            pause
            popd >nul
            exit /b 1
        )
        echo.
        echo [OK] Installation complete. Continuing...
        echo.
    ) else (
        echo.
        echo [INFO] Skipped. Install Visual Studio 2022 with C++ workload manually, then re-run.
        pause
        popd >nul
        exit /b 1
    )
    goto :preflight_done
)

if "!HAS_SDK!"=="0" (
    echo.
    echo ==============================================
    echo   MISSING: Windows 10/11 SDK
    echo ==============================================
    echo.
    echo Visual Studio 2022 with C++ was found, but no
    echo Windows SDK was detected. The SDK is required
    echo to compile for Win64.
    echo.
    set /p "INSTALL_SDK=Install !WIN_SDK_LABEL! now via winget? [Y/n]: "
    if /i "!INSTALL_SDK!" NEQ "n" (
        echo.
        echo [INFO] Installing !WIN_SDK_LABEL!...
        echo.
        winget install !WIN_SDK_PKG! --accept-source-agreements --accept-package-agreements
        if !ERRORLEVEL! NEQ 0 (
            echo [WARN] winget standalone SDK install failed. Trying via VS 2022 Build Tools modifier...
            winget install Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --add !WIN_SDK_COMPONENT!" --accept-source-agreements --accept-package-agreements
            if !ERRORLEVEL! NEQ 0 (
                echo.
                echo [ERROR] Could not install Windows SDK. Install it manually via
                echo         Visual Studio Installer: add a Windows 10/11 SDK component.
                pause
                popd >nul
                exit /b 1
            )
        )
        echo.
        echo [OK] !WIN_SDK_LABEL! installed. Continuing...
        echo.
    ) else (
        echo.
        echo [INFO] Skipped. Add a Windows SDK via Visual Studio Installer, then re-run.
        pause
        popd >nul
        exit /b 1
    )
)

:preflight_done

REM -----------------------------
REM Preflight: probe for a UE-preferred MSVC toolset (14.3x range)
REM Non-fatal: UE will compile with whatever MSVC is installed but prints
REM "is not a preferred version" warnings when only newer (14.4x) toolsets
REM are present, and that combination occasionally produces subtle compile
REM errors. Warn and name the exact VS Installer component to add; do not
REM block the build. The 14.3x heuristic covers UE 5.x preferred versions
REM through UE 5.6 and will need widening as UE moves to newer toolsets.
REM -----------------------------
if not "!HAS_VS!"=="1" goto :msvc_toolset_done
set "HAS_PREFERRED_MSVC=0"

if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%P in (`"%VSWHERE%" -products * -version [15.0^,^) -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2^>nul`) do (
        if "!HAS_PREFERRED_MSVC!"=="0" if exist "%%P\VC\Tools\MSVC" (
            for /f "delims=" %%T in ('dir /b /ad "%%P\VC\Tools\MSVC\14.3*" 2^>nul') do set "HAS_PREFERRED_MSVC=1"
        )
    )
)

REM Fallback filesystem scan, mirroring the VS-detection fallback, for VS
REM editions vswhere does not yet know about (e.g. VS 2026 Preview).
if "!HAS_PREFERRED_MSVC!"=="0" (
    for %%R in ("%ProgramFiles%\Microsoft Visual Studio" "%ProgramFiles(x86)%\Microsoft Visual Studio") do (
        if "!HAS_PREFERRED_MSVC!"=="0" if exist %%R (
            for /f "delims=" %%V in ('dir /b /ad %%R 2^>nul') do (
                if "!HAS_PREFERRED_MSVC!"=="0" (
                    for %%E in (Community Professional Enterprise BuildTools) do (
                        if "!HAS_PREFERRED_MSVC!"=="0" if exist "%%~R\%%V\%%E\VC\Tools\MSVC\" (
                            for /f "delims=" %%T in ('dir /b /ad "%%~R\%%V\%%E\VC\Tools\MSVC\14.3*" 2^>nul') do set "HAS_PREFERRED_MSVC=1"
                        )
                    )
                )
            )
        )
    )
)

if "!HAS_PREFERRED_MSVC!"=="1" goto :msvc_toolset_done
echo(
echo [WARN] No UE-preferred MSVC toolset ^(v14.3x^) detected.
echo        Unreal will warn the installed toolset is "not a preferred
echo        version" and may produce subtle compile errors. In Visual
echo        Studio Installer ^> Modify ^> Individual components, add
echo        "MSVC v143 - VS 2022 C++ x64/x86 build tools ^(v14.38-17.8^)".
echo        Continuing anyway.
echo(

:msvc_toolset_done

REM -----------------------------
REM Preflight: detect .NET Framework SDK 4.6+ (NetFxSDK)
REM Independent of the VS C++ workload and Windows SDK above: both can be
REM present and this still missing, in which case UBT aborts later with
REM "Unable to instantiate module 'SwarmInterface': Could not find NetFxSDK
REM install dir". On most machines the key is under the WOW6432Node view,
REM so both views are probed. A version subkey is not enough on its own:
REM the install folder must exist and contain the x64 reference libs
REM (the same thing UBT looks for), so a hollow leftover stub still fails.
REM -----------------------------
set "HAS_NETFXSDK=0"
set "NETFXSDK_VERSION="

for %%V in (4.8.1 4.8 4.7.2 4.7.1 4.7 4.6.2 4.6.1 4.6) do (
    if "!HAS_NETFXSDK!"=="0" (
        for %%R in ("HKLM\SOFTWARE\Microsoft\Microsoft SDKs\NETFXSDK" "HKLM\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\NETFXSDK") do (
            if "!HAS_NETFXSDK!"=="0" (
                set "NFX_DIR="
                for /f "tokens=2,*" %%A in ('reg query "%%~R\%%V" /v KitsInstallationFolder 2^>nul ^| find /i "REG_SZ"') do (
                    set "NFX_DIR=%%B"
                )
                if defined NFX_DIR (
                    if "!NFX_DIR:~-1!"=="\" set "NFX_DIR=!NFX_DIR:~0,-1!"
                    if exist "!NFX_DIR!\Lib\um\x64\mscoree.lib" (
                        set "HAS_NETFXSDK=1"
                        set "NETFXSDK_VERSION=%%V"
                    )
                )
            )
        )
    )
)

if "!HAS_NETFXSDK!"=="1" (
    echo [OK] Found: .NET Framework SDK !NETFXSDK_VERSION!
) else (
    echo [MISSING] .NET Framework SDK 4.6+ not found.
    echo(
    echo ==============================================
    echo   MISSING: .NET Framework SDK 4.6+
    echo ==============================================
    echo(
    echo Visual Studio's C++ workload and the Windows SDK
    echo were found, but Unreal Build Tool also needs the
    echo .NET Framework SDK ^(targeting pack^) to compile
    echo the SwarmInterface module. Without it the build
    echo fails with "Could not find NetFxSDK install dir".
    echo(
    set /p "INSTALL_NETFX=Install the .NET Framework Developer Pack now via winget? [Y/n]: "
    if /i "!INSTALL_NETFX!" NEQ "n" (
        echo(
        echo [INFO] Installing Microsoft .NET Framework Developer Pack...
        echo        This may take several minutes. An admin prompt may appear.
        echo(
        winget install Microsoft.DotNet.Framework.DeveloperPack_4 --accept-source-agreements --accept-package-agreements
        if !ERRORLEVEL! NEQ 0 (
            echo(
            echo [ERROR] winget install failed. Add the ".NET Framework
            echo         4.8 SDK" ^(or 4.6.2+^) via the Visual Studio
            echo         Installer ^> Individual components, then re-run.
            popd >nul
            pause
            exit /b 1
        )
        echo(
        echo [OK] Installation complete. Continuing...
        echo(
    ) else (
        echo(
        echo [INFO] Skipped. Add the ".NET Framework 4.6.2+ SDK" via the
        echo        Visual Studio Installer ^> Individual components, then re-run.
        popd >nul
        pause
        exit /b 1
    )
)

REM -----------------------------
REM Read EngineAssociation from .uproject
REM -----------------------------
set "ENGINE_ID="
for /f "usebackq tokens=1,2 delims=:" %%A in (`findstr /i /c:"EngineAssociation" "%UPROJECT%"`) do (
    set "ENGINE_ID=%%B"
)

if not defined ENGINE_ID (
    echo [ERROR] Could not read EngineAssociation from .uproject.
    pause
    popd >nul
    exit /b 1
)

REM Clean ENGINE_ID: remove spaces, commas, quotes, braces
set "ENGINE_ID=%ENGINE_ID: =%"
set "ENGINE_ID=%ENGINE_ID:,=%"
set "ENGINE_ID=%ENGINE_ID:\"=%"
set "ENGINE_ID=%ENGINE_ID:"=%"
set "ENGINE_ID=%ENGINE_ID:}=%"

echo [INFO] EngineAssociation: "%ENGINE_ID%"

REM Convert 5.7 -> UE_5.7 folder name pattern
set "ENGINE_FOLDER=UE_%ENGINE_ID%"

REM -----------------------------
REM Find Engine directory dynamically
REM 1) Try Launcher registry (HKLM\SOFTWARE\EpicGames\Unreal Engine\<ver>\InstalledDirectory)
REM 2) Try source-build registry (HKCU/HKLM \Software\Epic Games\Unreal Engine\Builds\<GUID>)
REM 3) Per-drive depth-limited search for UE_x.y folder (depth 0-2)
REM 4) Prompt user for manual path
REM -----------------------------
set "ENGINE_DIR="

REM (1) Launcher-installed engines: keyed by short version (e.g. "5.7"), not GUID.
REM     Works for the common case of a Launcher install regardless of whether UVS
REM     itself knows about the version (old Launcher UVS often pre-dates new engines).
for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\EpicGames\Unreal Engine\%ENGINE_ID%" /v InstalledDirectory 2^>nul ^| find /i "REG_SZ"') do (
    set "ENGINE_DIR=%%B"
)

REM (2) Source-build registry (GUID associations)
if not defined ENGINE_DIR (
    for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Epic Games\Unreal Engine\Builds" /v "%ENGINE_ID%" 2^>nul ^| find /i "REG_SZ"') do (
        set "ENGINE_DIR=%%B"
    )
)
if not defined ENGINE_DIR (
    for /f "tokens=2,*" %%A in ('reg query "HKLM\Software\Epic Games\Unreal Engine\Builds" /v "%ENGINE_ID%" 2^>nul ^| find /i "REG_SZ"') do (
        set "ENGINE_DIR=%%B"
    )
)

REM (3) Per-drive depth-limited search: for each drive, check root, then
REM     one folder deep, then two folders deep, before moving to the next drive.
REM     Fast for the common case (UE installed on C:) since it never touches
REM     other drives once a match is found.
if not defined ENGINE_DIR (
    echo [INFO] Searching for %ENGINE_FOLDER% folder across all drives...
    for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
        if not defined ENGINE_DIR if exist "%%D:\" (
            REM Depth 0: drive root (e.g. C:\UE_5.7)
            if exist "%%D:\%ENGINE_FOLDER%\Engine\Build\BatchFiles\Build.bat" (
                set "ENGINE_DIR=%%D:\%ENGINE_FOLDER%"
                goto :engine_found
            )
            REM Depth 1: one folder deep (e.g. C:\Epic Games\UE_5.7)
            for /f "delims=" %%P in ('dir /b /ad "%%D:\" 2^>nul') do (
                if not defined ENGINE_DIR if exist "%%D:\%%P\%ENGINE_FOLDER%\Engine\Build\BatchFiles\Build.bat" (
                    set "ENGINE_DIR=%%D:\%%P\%ENGINE_FOLDER%"
                    goto :engine_found
                )
            )
            REM Depth 2: two folders deep (e.g. C:\Program Files\Epic Games\UE_5.7)
            for /f "delims=" %%P in ('dir /b /ad "%%D:\" 2^>nul') do (
                if not defined ENGINE_DIR (
                    for /f "delims=" %%Q in ('dir /b /ad "%%D:\%%P\" 2^>nul') do (
                        if not defined ENGINE_DIR if exist "%%D:\%%P\%%Q\%ENGINE_FOLDER%\Engine\Build\BatchFiles\Build.bat" (
                            set "ENGINE_DIR=%%D:\%%P\%%Q\%ENGINE_FOLDER%"
                            goto :engine_found
                        )
                    )
                )
            )
        )
    )
)

:engine_found
if not defined ENGINE_DIR (
    echo [WARNING] Could not find %ENGINE_FOLDER% on this machine.
    echo.
    echo Please enter the full path to your %ENGINE_FOLDER% folder.
    echo Example: C:\Program Files\Epic Games\%ENGINE_FOLDER%
    echo.
    set /p "ENGINE_DIR=%ENGINE_FOLDER% path: "
)

if not defined ENGINE_DIR (
    echo [ERROR] No path provided. Aborting.
    pause
    popd >nul
    exit /b 1
)

REM Strip trailing backslash and quotes from user input
set "ENGINE_DIR=%ENGINE_DIR:"=%"
if "%ENGINE_DIR:~-1%"=="\" set "ENGINE_DIR=%ENGINE_DIR:~0,-1%"

if not exist "%ENGINE_DIR%\Engine" (
    echo [ERROR] Invalid engine path: "%ENGINE_DIR%"
    echo         Could not find Engine subfolder.
    pause
    popd >nul
    exit /b 1
)

set "BUILD_BAT=%ENGINE_DIR%\Engine\Build\BatchFiles\Build.bat"
if not exist "%BUILD_BAT%" (
    echo [ERROR] Build.bat not found at: "%BUILD_BAT%"
    pause
    popd >nul
    exit /b 1
)

echo [INFO] Engine  : "%ENGINE_DIR%"

REM -----------------------------
REM Detect UBT layout (UE4 vs UE5) and resolve dotnet for UE5
REM Done once upfront so both step 1/2 (generate) and step 2/2 (build)
REM can share the same invocation.
REM    UE5 -> Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.dll (invoked via bundled dotnet.exe)
REM    UE4 -> Engine\Binaries\DotNET\UnrealBuildTool.exe (.NET Framework, invoked directly)
REM -----------------------------
set "UBT_DLL=%ENGINE_DIR%\Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.dll"
set "UBT_EXE=%ENGINE_DIR%\Engine\Binaries\DotNET\UnrealBuildTool.exe"
set "UBT_KIND="
set "DOTNET_EXE="

if exist "%UBT_DLL%" (
    set "UBT_KIND=UE5"
    for /f "delims=" %%D in ('dir /b /s "%ENGINE_DIR%\Engine\Binaries\ThirdParty\DotNet\dotnet.exe" 2^>nul') do (
        if not defined DOTNET_EXE set "DOTNET_EXE=%%D"
    )
    if not defined DOTNET_EXE (
        echo [ERROR] Could not find bundled dotnet.exe under:
        echo         "%ENGINE_DIR%\Engine\Binaries\ThirdParty\DotNet"
        pause
        popd >nul
        exit /b 1
    )
    if not exist "!DOTNET_EXE!" (
        echo [ERROR] dotnet.exe path does not exist:
        echo         "!DOTNET_EXE!"
        pause
        popd >nul
        exit /b 1
    )
    echo [INFO] UBT     : "%UBT_DLL%" ^(UE5 .NET^)
    echo [INFO] DotNet  : "!DOTNET_EXE!"
) else if exist "%UBT_EXE%" (
    set "UBT_KIND=UE4"
    echo [INFO] UBT     : "%UBT_EXE%" ^(UE4 .NET Framework^)
) else (
    echo [ERROR] UnrealBuildTool not found. Looked for:
    echo         "%UBT_DLL%"
    echo         "%UBT_EXE%"
    pause
    popd >nul
    exit /b 1
)

REM -----------------------------
REM Step 1/2: Generate project files via UBT
REM Bypasses UnrealVersionSelector entirely: works whether or not the
REM Launcher knows about this engine version, and does not write to the
REM .uproject, so the file can stay read-only under source control.
REM -----------------------------
echo(
echo [INFO] Step 1/2: Generate project files...
echo(

call :run_ubt -projectfiles -project="%UPROJECT%" -game -rocket -progress
set "GEN_ERR=%ERRORLEVEL%"

echo(
if not "%GEN_ERR%"=="0" (
    echo [ERROR] Generate project files failed. ErrorLevel=%GEN_ERR%
    pause
    popd >nul
    exit /b %GEN_ERR%
)
echo [OK] Project files generated.

REM -----------------------------
REM Step 2/2: Build the editor target
REM -----------------------------
echo(
echo [INFO] Step 2/2: Build %PROJECT_NAME%Editor Win64 Development...
echo(

call :run_ubt %PROJECT_NAME%Editor Win64 Development -project="%UPROJECT%" -waitmutex
set "BUILD_ERR=%ERRORLEVEL%"

echo(
if not "%BUILD_ERR%"=="0" (
    echo [ERROR] Build failed. ErrorLevel=%BUILD_ERR%
    popd >nul
    pause
    exit /b %BUILD_ERR%
)

echo ======================================
echo   BUILD COMPLETE
echo ======================================
echo(
pause
exit

REM -----------------------------
REM :run_ubt -- invoke UnrealBuildTool with the launcher matching UBT_KIND.
REM Forwards all positional args (%*) to UBT and returns its ERRORLEVEL.
REM -----------------------------
:run_ubt
if "%UBT_KIND%"=="UE5" (
    "%DOTNET_EXE%" "%UBT_DLL%" %*
) else (
    "%UBT_EXE%" %*
)
exit /b %ERRORLEVEL%
