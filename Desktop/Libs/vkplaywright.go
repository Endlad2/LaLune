// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// vkplaywright.go - установка Chromium / Playwright driver для
// LaLuneTokenFetcher (Playwright).
//
// Если LaLuneTokenFetcher сообщает, что Playwright не инициализирован
// (маркер LALUNE_CHROMIUM_MISSING в выводе или код возврата 4) - это может
// быть либо отсутствующий Chromium, либо отсутствующий Playwright driver
// (node.exe в %APPDATA%\.playwright\node\...). Обе проблемы решает один и тот
// же установщик, поставляемый вместе с Microsoft.Playwright:
//
//     playwright.ps1 install chromium      (Windows)
//     playwright     install chromium      (Linux)
//
// Ключевой момент: playwright.ps1 - это PowerShell-скрипт, а не .exe/.cmd,
// поэтому его нужно запускать через `powershell -File ...`, иначе cmd.exe его
// не выполнит. Именно из-за этого раньше install не срабатывал и driver
// (node.exe) оставался неустановленным.

package libs

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

// ChromiumMissingMarker - строка, которую печатает fetcher, когда Playwright
// не инициализирован. Должна совпадать с Program.cs
// (LaLuneTokenFetcher.Playwright).
const ChromiumMissingMarker = "LALUNE_CHROMIUM_MISSING"

// playwrightCommand описывает один способ запуска Playwright CLI: argv[0] -
// исполняемый файл, argv[1:] - уже добавленные аргументы (например, для ps1:
// powershell -File <path>). К ним допишется "install chromium".
type playwrightCommand struct {
	argv []string
	desc string
}

// playwrightCandidates возвращает возможные способы запуска Playwright CLI,
// начиная с локального скрипта рядом с fetcher'ом.
func (a *AppCore) playwrightCandidates() []playwrightCommand {
	dir := a.vkFetcherDir()

	var list []playwrightCommand

	if runtime.GOOS == "windows" {
		ps1 := filepath.Join(dir, "playwright.ps1")
		// .ps1 нужно запускать через powershell -File, иначе cmd не выполнит.
		list = append(list,
			playwrightCommand{
				argv: []string{"powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1},
				desc: ps1 + " (powershell)",
			},
		)
		// .cmd и .exe - исполняемые напрямую.
		list = append(list,
			playwrightCommand{argv: []string{filepath.Join(dir, "playwright.cmd")}, desc: "playwright.cmd"},
			playwrightCommand{argv: []string{filepath.Join(dir, "playwright.exe")}, desc: "playwright.exe"},
		)
	} else {
		list = append(list, playwrightCommand{
			argv: []string{filepath.Join(dir, "playwright")},
			desc: filepath.Join(dir, "playwright"),
		})
	}

	// Глобальные варианты.
	list = append(list,
		playwrightCommand{argv: []string{"playwright"}, desc: "playwright (PATH)"},
		playwrightCommand{argv: []string{"dotnet", "playwright"}, desc: "dotnet playwright"},
	)

	return list
}

// installPlaywrightChromium выполняет `playwright install chromium`.
// Это устанавливает и Playwright driver (node), и браузер Chromium.
// Возвращает nil, если установка успешно завершилась.
func (a *AppCore) installPlaywrightChromium() error {
	a.AddLog("[VK] Playwright/Chromium не готов, устанавливаю через Playwright...")

	var lastErr error
	for _, cand := range a.playwrightCandidates() {
		argv := append(append([]string{}, cand.argv...), "install", "chromium")

		cmd := exec.Command(argv[0], argv[1:]...)
		cmd.Dir = a.vkFetcherDir()

		stdout, err := cmd.StdoutPipe()
		if err != nil {
			lastErr = err
			continue
		}
		stderr, err := cmd.StderrPipe()
		if err != nil {
			lastErr = err
			continue
		}

		if err := cmd.Start(); err != nil {
			// Кандидат недоступен (нет файла / не в PATH) - пробуем следующий.
			lastErr = err
			continue
		}

		streamLog := func(r interface{ Read([]byte) (int, error) }) {
			sc := bufio.NewScanner(r)
			for sc.Scan() {
				a.AddLog("[VK][playwright] " + sc.Text())
			}
		}
		go streamLog(stdout)
		go streamLog(stderr)

		if err := cmd.Wait(); err != nil {
			lastErr = err
			a.AddLog(fmt.Sprintf("[VK] Установка Playwright/Chromium через %q не удалась: %v", cand.desc, err))
			continue
		}

		a.AddLog("[VK] Playwright/Chromium успешно установлен")
		return nil
	}

	if lastErr == nil {
		lastErr = fmt.Errorf("playwright CLI не найден")
	}
	return fmt.Errorf("не удалось установить Playwright/Chromium: %w", lastErr)
}

// fetcherReportsMissingChromium проверяет вывод/код возврата fetcher'а.
func fetcherReportsMissingChromium(output string, exitCode int) bool {
	if exitCode == 4 {
		return true
	}
	return len(output) > 0 && containsMarker(output, ChromiumMissingMarker)
}

// containsMarker - простая проверка подстроки без лишних зависимостей.
func containsMarker(haystack, marker string) bool {
	if len(marker) == 0 || len(haystack) < len(marker) {
		return false
	}
	for i := 0; i+len(marker) <= len(haystack); i++ {
		if haystack[i:i+len(marker)] == marker {
			return true
		}
	}
	return false
}

// fetcherExeExists - небольшая обёртка для тестов/логов.
func (a *AppCore) fetcherExeExists() bool {
	_, err := os.Stat(a.vkFetcherExePath())
	return err == nil
}
