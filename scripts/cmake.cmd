@echo off
REM ---------------------------------------------------------------------------
REM  cmake.cmd — wrapper вокруг настоящего cmake.exe.
REM
REM  Flutter для Windows жёстко передаёт `-G "Visual Studio 16 2019"` в
REM  командной строке CMake, игнорируя env-переменную CMAKE_GENERATOR.
REM  Аргумент -G приоритетнее env и set(... FORCE) в CMakeLists.txt.
REM  Этот враппер вырезает -G и -A из аргументов и подставляет генератор
REM  из %CMAKE_GENERATOR% (VS 17 2022, потому что мы ставим BuildTools 2022).
REM ---------------------------------------------------------------------------

setlocal EnableDelayedExpansion

REM Находим настоящий cmake.exe, минуя эту папку scripts/.
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
