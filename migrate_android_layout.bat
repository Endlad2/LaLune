@echo off
REM ============================================================
REM  migrate_android_layout.bat
REM
REM  Moves the Android project into the Flutter project tree:
REM    Frontend\Core\android\app\src\main\java\com\lalune\app\   (Kotlin sources)
REM    Frontend\Core\android\app\src\main\res\                    (resources)
REM    Frontend\Core\android\app\src\main\AndroidManifest.xml
REM    Frontend\Core\android\app\build.gradle
REM    Frontend\Core\android\build.gradle
REM    Frontend\Core\android\settings.gradle
REM    Frontend\Core\android\gradle.properties
REM
REM  After this script, Mobile\Android\ contains no source code and can be removed.
REM
REM  Usage:
REM    migrate_android_layout.bat             - interactive
REM    migrate_android_layout.bat --dry-run   - show only
REM    migrate_android_layout.bat --yes       - no confirmation
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
echo   LaLune Android layout migration
echo ============================================================
echo   Root:     %CD%
if "%DRY_RUN%"=="1" echo   Mode:     DRY-RUN (nothing will be changed)
if "%AUTO_YES%"=="1" echo   Mode:     auto-confirm
echo.

if not exist "Mobile\Android" (
    echo [SKIP]  Mobile\Android not found - nothing to migrate
    endlocal
    exit /b 0
)

if not exist "Frontend\Core" (
    echo [ERROR] Frontend\Core not found - is this the repo root?
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

REM ---------- 1. Kotlin sources ----------
echo.
echo [1] Kotlin sources
if exist "Mobile\Android\app\src\main\java\com\lalune\app" (
    if "%DRY_RUN%"=="1" (
        echo   [WOULD COPY] Mobile\Android\app\src\main\java\com\lalune\app -^> Frontend\Core\android\app\src\main\java\com\lalune\app
    ) else (
        if not exist "Frontend\Core\android\app\src\main\java\com\lalune\app" mkdir "Frontend\Core\android\app\src\main\java\com\lalune\app"
        xcopy /E /I /Y /Q "Mobile\Android\app\src\main\java\com\lalune\app" "Frontend\Core\android\app\src\main\java\com\lalune\app" >nul
        if exist "Frontend\Core\android\app\src\main\java\com\lalune\app\MainActivity.kt" (
            echo   [ OK ]  copied Kotlin sources
        ) else (
            echo   [FAIL]  copy failed
        )
    )
) else (
    echo   [SKIP]  Mobile\Android\app\src\main\java\com\lalune\app not found
)

REM ---------- 2. Resources ----------
echo.
echo [2] Android resources
if exist "Mobile\Android\app\src\main\res" (
    if "%DRY_RUN%"=="1" (
        echo   [WOULD COPY] Mobile\Android\app\src\main\res -^> Frontend\Core\android\app\src\main\res
    ) else (
        if not exist "Frontend\Core\android\app\src\main\res" mkdir "Frontend\Core\android\app\src\main\res"
        xcopy /E /I /Y /Q "Mobile\Android\app\src\main\res" "Frontend\Core\android\app\src\main\res" >nul
        echo   [ OK ]  copied res
    )
) else (
    echo   [SKIP]  Mobile\Android\app\src\main\res not found
)

REM ---------- 3. Assets (Lua) ----------
echo.
echo [3] Android assets (SmartTunnel.lua)
if exist "Mobile\Android\app\src\main\assets\SmartTunnel.lua" (
    if "%DRY_RUN%"=="1" (
        echo   [WOULD COPY] Mobile\Android\app\src\main\assets\SmartTunnel.lua -^> Frontend\Core\android\app\src\main\assets\SmartTunnel.lua
    ) else (
        if not exist "Frontend\Core\android\app\src\main\assets" mkdir "Frontend\Core\android\app\src\main\assets"
        copy /Y "Mobile\Android\app\src\main\assets\SmartTunnel.lua" "Frontend\Core\android\app\src\main\assets\SmartTunnel.lua" >nul
        echo   [ OK ]  copied SmartTunnel.lua
    )
) else (
    echo   [SKIP]  Mobile\Android\app\src\main\assets\SmartTunnel.lua not found
)

REM ---------- 4. jniLibs ----------
echo.
echo [4] Android jniLibs
if exist "Mobile\Android\app\src\main\jniLibs" (
    if "%DRY_RUN%"=="1" (
        echo   [WOULD COPY] Mobile\Android\app\src\main\jniLibs -^> Frontend\Core\android\app\src\main\jniLibs
    ) else (
        if not exist "Frontend\Core\android\app\src\main\jniLibs" mkdir "Frontend\Core\android\app\src\main\jniLibs"
        xcopy /E /I /Y /Q "Mobile\Android\app\src\main\jniLibs" "Frontend\Core\android\app\src\main\jniLibs" >nul
        echo   [ OK ]  copied jniLibs
    )
) else (
    echo   [SKIP]  Mobile\Android\app\src\main\jniLibs not found
)

REM ---------- 5. Gradle files ----------
echo.
echo [5] Gradle files
if exist "Mobile\Android\gradle\wrapper" (
    if "%DRY_RUN%"=="1" (
        echo   [WOULD COPY] gradle\wrapper
    ) else (
        if not exist "Frontend\Core\android\gradle\wrapper" mkdir "Frontend\Core\android\gradle\wrapper"
        xcopy /E /I /Y /Q "Mobile\Android\gradle\wrapper" "Frontend\Core\android\gradle\wrapper" >nul
        echo   [ OK ]  gradle\wrapper
    )
) else (
    echo   [SKIP]  Mobile\Android\gradle\wrapper not found
)

for %%F in (gradlew gradlew.bat gradle.properties) do (
    if exist "Mobile\Android\%%F" (
        if "%DRY_RUN%"=="1" (
            echo   [WOULD COPY] %%F
        ) else (
            copy /Y "Mobile\Android\%%F" "Frontend\Core\android\%%F" >nul
            echo   [ OK ]  %%F
        )
    )
)

REM ---------- 6. Delete Mobile\Android ----------
echo.
echo [6] Remove Mobile\Android
if "%DRY_RUN%"=="1" (
    echo   [WOULD DELETE] Mobile\Android
) else (
    rmdir /s /q "Mobile\Android"
    if exist "Mobile\Android\" (
        echo   [FAIL]  could not remove Mobile\Android
    ) else (
        echo   [ OK ]  Mobile\Android removed
    )
)

echo.
echo ============================================================
echo   Migration finished
echo ============================================================
echo.
echo Next: build Android APK
echo   cd Frontend\Core
echo   flutter build apk --release
echo.

endlocal
exit /b 0
