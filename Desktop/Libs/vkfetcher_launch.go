// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// vkfetcher_launch.go - запуск LaLuneTokenFetcher с перехватом вывода.
//
// Windows:
//   Кнопка «Войти» вызывает RunFetcherWithFallback() -> runFetcherWithFallback()
//   -> startFetcherViaTokenPS(). Он:
//     1) проверяет, что в <vk-token-fetcher>/browsers лежит chromium-XXXX;
//        если нет - возвращает ошибку и НИЧЕГО не запускает;
//     2) запускает в ВИДИМОМ окне PowerShell:
//          powershell -NoProfile -ExecutionPolicy Bypass -Command `
//              "irm https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Token.ps1 | iex"
//        Скрипт сам ставит PLAYWRIGHT_BROWSERS_PATH, качает ZIP, распаковывает
//        и запускает LaLuneTokenFetcher.exe.
//
// Linux/macOS:
//   Логика та же, что и раньше - fetcher запускается напрямую, с
//   PLAYWRIGHT_BROWSERS_PATH=<vk-token-fetcher>/browsers и флагом
//   fetcherAlive (нужен UI, чтобы не крутить бесконечное «Ожидание…»).

package libs

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
)

// tokenPSURL - one-command скрипт с GitHub, который скачивает ZIP,
// распаковывает его, выставляет PLAYWRIGHT_BROWSERS_PATH и запускает
// LaLuneTokenFetcher.exe с видимым окном.
const tokenPSURL = "https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Token.ps1"

// fetcherAlive - 1, если процесс fetcher'а сейчас запущен, 0 - иначе.
var fetcherAlive int32

// fetcherIsAlive сообщает, работает ли fetcher в данный момент.
func fetcherIsAlive() bool {
	return atomic.LoadInt32(&fetcherAlive) == 1
}

// fetcherRun - обёртка над запущенным процессом fetcher'а.
type fetcherRun struct {
	cmd *exec.Cmd
	buf *bytes.Buffer
	mu  sync.Mutex
}

// wait дожидается завершения процесса и возвращает накопленный вывод и код.
func (r *fetcherRun) wait() (string, int) {
	err := r.cmd.Wait()

	// Процесс завершился - снимаем флаг "жив".
	atomic.StoreInt32(&fetcherAlive, 0)

	r.mu.Lock()
	out := r.buf.String()
	r.mu.Unlock()

	code := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			code = -1
		}
	}
	return out, code
}

// hasChromiumInstalled проверяет, что в <vk-token-fetcher>/browsers лежит
// хотя бы одна папка chromium-XXXX.
func (a *AppCore) hasChromiumInstalled() bool {
	dir := a.playwrightBrowsersPath()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		if len(name) >= 8 && name[:8] == "chromium" {
			return true
		}
	}
	return false
}

// startFetcherViaTokenPS - только Windows.
// Запускает one-command PowerShell-скрипт Token.ps1 в ВИДИМОМ окне.
//
// Перед запуском проверяет наличие Chromium в <vk-token-fetcher>/browsers:
// если его нет - возвращает ошибку и ничего не запускает.
func (a *AppCore) startFetcherViaTokenPS() error {
	browsersPath := a.playwrightBrowsersPath()

	if !a.hasChromiumInstalled() {
		return fmt.Errorf(
			"Chromium не установлен в %s — сначала установите Chromium "+
				"(кнопка «Установить Chromium» или переустановите LaLuneTokenFetcher)",
			browsersPath,
		)
	}

	// Внутренняя команда. Оборачиваем в try/catch, чтобы окно не мигало
	// и закрывалось мгновенно при ошибке — иначе пользователь не увидит,
	// что пошло не так.
	inner := fmt.Sprintf(
		"$ErrorActionPreference='Continue'; "+
			"$Env:PLAYWRIGHT_BROWSERS_PATH='%s'; "+
			"try { irm %s | iex } catch { "+
			"Write-Host ('[Token.ps1] Ошибка: ' + $_.Exception.Message) -ForegroundColor Red; "+
			"Read-Host 'Нажмите Enter, чтобы закрыть окно' }",
		escapeSingleQuotes(browsersPath),
		tokenPSURL,
	)

	// cmd.exe "start" гарантирует НОВОЕ видимое окно powershell,
	// независимо от того, есть ли у родительского процесса своя консоль.
	cmd := exec.Command(
		"cmd", "/c", "start", "", "powershell",
		"-NoProfile", "-ExecutionPolicy", "Bypass",
		"-Command", inner,
	)
	cmd.Dir = a.vkFetcherDir()
	cmd.Env = append(os.Environ(),
		"PLAYWRIGHT_BROWSERS_PATH="+browsersPath,
		"PLAYWRIGHT_SKIP_BROWSER_GC=1",
	)

	a.AddLog("[VK] Запускаю Token.ps1 в отдельном окне PowerShell")
	a.AddLog("[VK] PLAYWRIGHT_BROWSERS_PATH=" + browsersPath)

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("не удалось запустить PowerShell: %w", err)
	}
	// Не ждём завершения — окно живёт своей жизнью, UI поллит token.json.
	_ = cmd.Process.Release()
	return nil
}

// escapeSingleQuotes - экранирует одинарные кавычки для встраивания
// строки в PowerShell-литерал в одинарных кавычках.
func escapeSingleQuotes(s string) string {
	return strings.ReplaceAll(s, "'", "''")
}

// startFetcherCaptured запускает fetcher напрямую (Linux/macOS),
// перенаправляя stdout+stderr в буфер.
//
// На Windows этот путь больше не используется — там идёт
// startFetcherViaTokenPS() с видимым окном PowerShell.
func (a *AppCore) startFetcherCaptured() (*fetcherRun, error) {
	exe := a.vkFetcherExePath()

	cmd := exec.Command(exe)
	cmd.Dir = a.vkFetcherDir()

	browsersPath := a.playwrightBrowsersPath()
	cmd.Env = append(os.Environ(),
		"PLAYWRIGHT_BROWSERS_PATH="+browsersPath,
		"PLAYWRIGHT_SKIP_BROWSER_GC=1",
	)

	buf := &bytes.Buffer{}
	cmd.Stdout = buf
	cmd.Stderr = buf

	if err := cmd.Start(); err != nil {
		atomic.StoreInt32(&fetcherAlive, 0)
		return nil, err
	}

	atomic.StoreInt32(&fetcherAlive, 1)

	a.AddLog("[VK] Token fetcher запущен (PLAYWRIGHT_BROWSERS_PATH=" + browsersPath + ")")

	return &fetcherRun{cmd: cmd, buf: buf}, nil
}

// runFetcherWithFallback - точка входа, которую дёргает LoginVK().
//
//   * Windows: startFetcherViaTokenPS() — one-command Token.ps1 в видимом
//     окне. Проверка Chromium уже внутри.
//   * Linux/macOS: startFetcherCaptured() с фоновым watchdog'ом на случай
//     LALUNE_CHROMIUM_MISSING (старая логика, без изменений).
func (a *AppCore) runFetcherWithFallback() error {
	if runtime.GOOS == "windows" {
		return a.startFetcherViaTokenPS()
	}

	// ---------- Linux / macOS: как было ----------
	run, err := a.startFetcherCaptured()
	if err != nil {
		return err
	}

	go func() {
		output, code := run.wait()

		if !fetcherReportsMissingChromium(output, code) {
			return
		}

		a.AddLog("[VK] Fetcher сообщил об отсутствии Chromium")

		if ierr := a.installPlaywrightChromium(); ierr != nil {
			a.AddLog("[VK] Не удалось установить Chromium: " + ierr.Error())
			return
		}

		if _, rerr := a.startFetcherCaptured(); rerr != nil {
			a.AddLog("[VK] Не удалось перезапустить fetcher: " + rerr.Error())
		}
	}()

	return nil
}

// RunFetcherWithFallback - экспортная обёртка для вызова из платформенных
// app_*.go (LoginVK). Делает ровно то же, что runFetcherWithFallback.
func (a *AppCore) RunFetcherWithFallback() error {
	return a.runFetcherWithFallback()
}
