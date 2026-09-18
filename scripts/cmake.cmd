@echo off
REM ---------------------------------------------------------------------------
REM  cmake.cmd — wrapper вокруг настоящего cmake.exe.
REM
REM  Flutter для Windows жёстко передаёт `-G "Visual Studio 16 2019"`.
REM  Основной фикс — патч flutter_tools в workflow, но этот враппер
REM  остаётся как второй рубеж: если Flutter всё-таки вызовет cmake
REM  через PATH (а не по абсолютному пути), враппер подменит -G.
REM ---------------------------------------------------------------------------

setlocal EnableDelayedExpansion

set "REAL_CMAKE="
for %%P in ("%PATH:;=" "%") do (
    if exist "%%~P\cmake.exe" (
        echo %%~P | findstr /I /C:"\scripts" >nul
        if errorlevel 1 (
            set "REAL_CMAKE=%%~P\cmake.exe"
            goto :found
        )
    )
)

:found
if "%REAL_CMAKE%"=="" (
    echo [cmake-wrapper] ERROR: real cmake.exe not found in PATH 1>&2
    exit /b 1
)

set "NEW_ARGS="
set "SKIP_NEXT="

for %%A in (%*) do (
    if defined SKIP_NEXT (
        set "SKIP_NEXT="
    ) else (
        if /I "%%~A"=="-G" (
            set "SKIP_NEXT=1"
        ) else if /I "%%~A"=="-A" (
            set "SKIP_NEXT=1"
        ) else (
            set "NEW_ARGS=!NEW_ARGS! %%A"
        )
    )
)

if not "%CMAKE_GENERATOR%"=="" (
    set "NEW_ARGS=-G "%CMAKE_GENERATOR%" !NEW_ARGS!"
    echo [cmake-wrapper] overriding generator: %CMAKE_GENERATOR%
)

"%REAL_CMAKE%" !NEW_ARGS!
exit /b %ERRORLEVEL%
