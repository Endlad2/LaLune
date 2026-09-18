@echo off
REM ============================================================
REM  migrate_desktop_layout.bat
REM
REM  Consolidates the Desktop Go module into Desktop\Libs\ :
REM    1. Move Desktop\cmd\main.go        -> Desktop\Libs\cmd\main.go
REM    2. Move Desktop\Linux\platform_linux.go   -> Desktop\Libs\platform_linux.go
REM    3. Move Desktop\Windows\platform_windows.go -> Desktop\Libs\platform_windows.go
REM    4. Rename Desktop\Linux\icon.png  -> Desktop\Linux_icon.png
REM       Rename Desktop\Windows\icon.ico-> Desktop\Windows_icon.ico
REM    5. Rewrite Desktop\Libs\go.mod as "module lalune-libs"
REM    6. Delete Desktop\Libs\go.sum and run "go mod tidy"
REM    7. Strip the "lalune-desktop/Libs" import line from Desktop\Libs\capi.go
REM
REM  Usage:
REM    migrate_desktop_layout.bat             - interactive
REM    migrate_desktop_layout.bat --dry-run   - show only, do not touch
REM    migrate_desktop_layout.bat --yes       - no confirmation
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

echo.
echo ============================================================
echo   LaLune desktop layout migration
echo ============================================================
echo   Root:     %CD%
if "%DRY_RUN%"=="1" echo   Mode:     DRY-RUN (nothing will be changed)
if "%AUTO_YES%"=="1" echo   Mode:     auto-confirm
echo.

REM ---------- Preflight ----------
if not exist "Desktop\Libs" (
    echo [ERROR] Desktop\Libs not found. Run from repository root.
    endlocal
    exit /b 1
)

if "%AUTO_YES%"=="0" if "%DRY_RUN%"=="0" (
    set /p "CONFIRM=Proceed? [y/N]: "
    if /I not "!CONFIRM!"=="y" (
        echo Cancelled.
        endlocal
        exit /b 0
    )
)

REM ---------- 1. cmd\main.go ----------
echo.
echo [1] Desktop\cmd\main.go -^> Desktop\Libs\cmd\main.go
if exist "Desktop\cmd\main.go" (
    if "%DRY_RUN%"=="1" (
        echo   [WOULD MOVE]
    ) else (
        if not exist "Desktop\Libs\cmd" mkdir "Desktop\Libs\cmd"
        move /Y "Desktop\cmd\main.go" "Desktop\Libs\cmd\main.go" >nul
        if exist "Desktop\Libs\cmd\main.go" (
            echo   [ OK ]  moved
        ) else (
            echo   [FAIL]  move failed
        )
        REM Try to remove the now-empty Desktop\cmd directory
        rmdir "Desktop\cmd" >nul 2>&1
        if exist "Desktop\cmd\" (
            echo   [INFO]  Desktop\cmd is not empty, leaving it
        ) else (
            echo   [ OK ]  Desktop\cmd removed
        )
    )
) else (
    if exist "Desktop\Libs\cmd\main.go" (
        echo   [SKIP]  already at target
    ) else (
        echo   [SKIP]  source not found
    )
)

REM ---------- 2. platform_linux.go ----------
echo.
echo [2] Desktop\Linux\platform_linux.go -^> Desktop\Libs\platform_linux.go
if exist "Desktop\Linux\platform_linux.go" (
    if "%DRY_RUN%"=="1" (
        echo   [WOULD MOVE]
    ) else (
        move /Y "Desktop\Linux\platform_linux.go" "Desktop\Libs\platform_linux.go" >nul
        if exist "Desktop\Libs\platform_linux.go" (
            echo   [ OK ]  moved
        ) else (
            echo   [FAIL]  move failed
        )
    )
) else (
    if exist "Desktop\Libs\platform_linux.go" (
        echo   [SKIP]  already at target
    ) else (
        echo   [SKIP]  source not found
    )
)

REM ---------- 3. platform_windows.go ----------
echo.
echo [3] Desktop\Windows\platform_windows.go -^> Desktop\Libs\platform_windows.go
if exist "Desktop\Windows\platform_windows.go" (
    if "%DRY_RUN%"=="1" (
        echo   [WOULD MOVE]
    ) else (
        move /Y "Desktop\Windows\platform_windows.go" "Desktop\Libs\platform_windows.go" >nul
        if exist "Desktop\Libs\platform_windows.go" (
            echo   [ OK ]  moved
        ) else (
            echo   [FAIL]  move failed
        )
    )
) else (
    if exist "Desktop\Libs\platform_windows.go" (
        echo   [SKIP]  already at target
    ) else (
        echo   [SKIP]  source not found
    )
)

REM ---------- 4. icons ----------
echo.
echo [4] Icons
if exist "Desktop\Linux\icon.png" (
    if "%DRY_RUN%"=="1" (
        echo   [WOULD RENAME] Desktop\Linux\icon.png -^> Desktop\Linux_icon.png
    ) else (
        if exist "Desktop\Linux_icon.png" (
            echo   [SKIP]  Desktop\Linux_icon.png already exists
        ) else (
            move /Y "Desktop\Linux\icon.png" "Desktop\Linux_icon.png" >nul
            echo   [ OK ]  Desktop\Linux_icon.png
        )
    )
) else (
    echo   [SKIP]  Desktop\Linux\icon.png not found
)

if exist "Desktop\Windows\icon.ico" (
    if "%DRY_RUN%"=="1" (
        echo   [WOULD RENAME] Desktop\Windows\icon.ico -^> Desktop\Windows_icon.ico
    ) else (
        if exist "Desktop\Windows_icon.ico" (
            echo   [SKIP]  Desktop\Windows_icon.ico already exists
        ) else (
            move /Y "Desktop\Windows\icon.ico" "Desktop\Windows_icon.ico" >nul
            echo   [ OK ]  Desktop\Windows_icon.ico
        )
    )
) else (
    echo   [SKIP]  Desktop\Windows\icon.ico not found
)

REM ---------- 5. go.mod ----------
echo.
echo [5] Rewrite Desktop\Libs\go.mod
if "%DRY_RUN%"=="1" (
    echo   [WOULD WRITE]
) else (
    > "Desktop\Libs\go.mod" (
        echo module lalune-libs
        echo.
        echo go 1.22
        echo.
        echo require ^(
        echo     github.com/google/uuid v1.6.0
        echo     github.com/yuin/gopher-lua v1.1.1
        echo     modernc.org/sqlite v1.29.5
        echo ^)
    )
    echo   [ OK ]  wrote Desktop\Libs\go.mod
)

REM ---------- 6. go.sum + go mod tidy ----------
echo.
echo [6] Desktop\Libs\go.sum and go mod tidy
if "%DRY_RUN%"=="1" (
    echo   [WOULD DELETE] Desktop\Libs\go.sum
    echo   [WOULD RUN]    go mod tidy  ^(cwd: Desktop\Libs^)
) else (
    if exist "Desktop\Libs\go.sum" (
        del /f /q "Desktop\Libs\go.sum"
        echo   [ OK ]  deleted Desktop\Libs\go.sum
    ) else (
        echo   [SKIP]  Desktop\Libs\go.sum not present
    )

    where go >nul 2>&1
    if errorlevel 1 (
        echo   [WARN]  go is not in PATH; run "go mod tidy" manually in Desktop\Libs\
    ) else (
        pushd "Desktop\Libs"
        echo   [RUN]   go mod tidy
        go mod tidy
        if errorlevel 1 (
            echo   [FAIL]  go mod tidy returned an error
        ) else (
            echo   [ OK ]  go mod tidy succeeded
        )
        popd
    )
)

REM ---------- 7. capi.go: strip self-import ----------
echo.
echo [7] Strip self-import from Desktop\Libs\capi.go
if exist "Desktop\Libs\capi.go" (
    if "%DRY_RUN%"=="1" (
        echo   [WOULD PATCH] remove line with "lalune-desktop/Libs"
    ) else (
        findstr /C:"lalune-desktop/Libs" "Desktop\Libs\capi.go" >nul 2>&1
        if errorlevel 1 (
            echo   [SKIP]  no self-import found
        ) else (
            set "CAPI_TMP=%TEMP%\capi_%RANDOM%.tmp"
            set "REMOVED=0"
            > "!CAPI_TMP!" (
                for /f "usebackq delims=" %%L in ("Desktop\Libs\capi.go") do (
                    set "LINE=%%L"
                    REM Check if this line contains the self-import
                    echo !LINE!| findstr /C:"lalune-desktop/Libs" >nul
                    if errorlevel 1 (
                        echo %%L
                    ) else (
                        set "REMOVED=1"
                    )
                )
            )
            move /Y "!CAPI_TMP!" "Desktop\Libs\capi.go" >nul
            if "!REMOVED!"=="1" (
                echo   [ OK ]  removed self-import line
            ) else (
                echo   [SKIP]  nothing removed
            )
        )
    )
) else (
    echo   [SKIP]  Desktop\Libs\capi.go not found
)

REM ---------- 8. platform.go sanity check ----------
echo.
echo [8] Desktop\Libs\platform.go sanity
if exist "Desktop\Libs\platform.go" (
    findstr /C:"package libs" "Desktop\Libs\platform.go" >nul 2>&1
    if errorlevel 1 (
        echo   [WARN]  package declaration is not "package libs"
    ) else (
        echo   [ OK ]  package libs
    )
) else (
    echo   [SKIP]  Desktop\Libs\platform.go not found
)

echo.
echo ============================================================
echo   Migration finished
echo ============================================================
echo.
echo Next steps:
echo   python prepare_st.py --platform=all
echo   python build_frontend.py --platform Windows
echo   python build_desktop.py --platform Windows
echo.
echo If go mod tidy failed, run it manually:
echo   cd Desktop\Libs ^&^& go mod tidy
echo.

endlocal
exit /b 0
