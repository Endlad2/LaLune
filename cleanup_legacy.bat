@echo off
REM ============================================================
REM  cleanup_legacy.bat
REM
REM  Removes Wails-specific and legacy files after migration
REM  to native Flutter + C-ABI.
REM
REM  After this script, the Desktop module lives in Desktop\Libs\ :
REM    Desktop\Libs\go.mod          (module lalune-libs)
REM    Desktop\Libs\cmd\main.go     (c-shared entrypoint)
REM    Desktop\Libs\*.go            (package libs)
REM
REM  Usage:
REM    cleanup_legacy.bat             - interactive
REM    cleanup_legacy.bat --dry-run   - show only, do not delete
REM    cleanup_legacy.bat --yes       - no confirmation
REM ============================================================

setlocal EnableDelayedExpansion
cd /d "%~dp0"

set "DRY_RUN=0"
set "AUTO_YES=0"

:parse_args
if "%~1"=="" goto after_args
if /I "%~1"=="--dry-run" set "DRY_RUN=1"
if /I "%~1"=="--yes" set "AUTO_YES=1"
shift
goto parse_args
:after_args

set "LIST_FILE=%TEMP%\lalune_cleanup_list_%RANDOM%.txt"
> "%LIST_FILE%" (
    echo Desktop\Linux\wails.json
    echo Desktop\Linux\app.go
    echo Desktop\Linux\app_linux.go
    echo Desktop\Linux\platform_linux.go
    echo Desktop\Linux\go.mod
    echo Desktop\Linux\go.sum
    echo Desktop\Windows\wails.json
    echo Desktop\Windows\app.go
    echo Desktop\Windows\app_windows.go
    echo Desktop\Windows\platform_windows.go
    echo Desktop\Windows\go.mod
    echo Desktop\Windows\go.sum
    echo Desktop\Windows\wails.exe.manifest
    echo Desktop\cmd
    echo Frontend\Core\web
    echo Frontend\output
    echo Frontend\Api
    echo Frontend\ios.js
    echo prepare_android_html.py
    echo .github\workflows\build-android.yml.new
)

echo.
echo ============================================================
echo   LaLune legacy cleanup
echo ============================================================
echo   Root:     %CD%
if "%DRY_RUN%"=="1" echo   Mode:     DRY-RUN (nothing will be deleted)
if "%AUTO_YES%"=="1" echo   Mode:     auto-confirm
echo.

echo === Targets ===
for /f "usebackq delims=" %%T in ("%LIST_FILE%") do (
    if exist "%%T" (
        echo   [FOUND]  %%T
    ) else (
        echo   [SKIP ]  %%T   ^(not found^)
    )
)
echo.

if "%DRY_RUN%"=="1" (
    echo DRY-RUN complete. Nothing was deleted.
    del /f /q "%LIST_FILE%" >nul 2>&1
    endlocal
    exit /b 0
)

if "%AUTO_YES%"=="0" (
    set /p "CONFIRM=Delete the listed paths? [y/N]: "
    if /I not "!CONFIRM!"=="y" (
        echo Cancelled.
        del /f /q "%LIST_FILE%" >nul 2>&1
        endlocal
        exit /b 0
    )
)

echo.
echo === Deleting ===
for /f "usebackq delims=" %%T in ("%LIST_FILE%") do (
    if exist "%%T\" (
        rmdir /s /q "%%T"
        if exist "%%T\" (
            echo   [FAIL]  %%T   ^(dir still exists^)
        ) else (
            echo   [ OK ]  %%T
        )
    ) else (
        if exist "%%T" (
            del /f /q "%%T"
            if exist "%%T" (
                echo   [FAIL]  %%T   ^(file still exists^)
            ) else (
                echo   [ OK ]  %%T
            )
        ) else (
            echo   [SKIP]  %%T   ^(already absent^)
        )
    )
)

del /f /q "%LIST_FILE%" >nul 2>&1

echo.
echo === Done ===
echo.
echo Kept intact:
echo   Desktop\Libs\go.mod              ^(module lalune-libs^)
echo   Desktop\Libs\cmd\main.go         ^(c-shared entrypoint^)
echo   Desktop\Libs\platform_linux.go
echo   Desktop\Libs\platform_windows.go
echo   Desktop\Linux\icon.png           ^(asset for future installer^)
echo   Desktop\Windows\icon.ico         ^(asset for future installer^)
echo   Frontend\Core\lib\               ^(Dart code^)
echo   Mobile\Android\app\src\main\java\com\lalune\app\   ^(Kotlin^)
echo.

endlocal
exit /b 0
