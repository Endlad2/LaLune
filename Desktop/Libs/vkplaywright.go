// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// vkplaywright.go - установка Chromium для LaLuneTokenFetcher (Playwright).
//
// Если LaLuneTokenFetcher сообщает, что Chromium не установлен (маркер
// LALUNE_CHROMIUM_MISSING в выводе или код возврата 4), Go backend запускает
// Playwright-скрипт установки браузера:
//
//     playwright install chromium
//
// Скрипт-обёртка `playwright` (или `playwright.ps1` в Windows) поставляется
// вместе с Microsoft.Playwright и лежит рядом с fetcher'ом. Если его нет,
// пробуем глобальный `playwright` из PATH и `dotnet playwright`.

package libs

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

// ChromiumMissingMarker - строка, которую печатает fetcher, когда Chromium
// не установлен. Должна совпадать с Program.cs (LaLuneTokenFetcher.Playwright).
const ChromiumMissingMarker = "LALUNE_CHROMIUM_MISSING"

// playwrightCandidates возвращает возможные способы запуска Playwright CLI,
// начиная с локального скрипта рядом с fetcher'ом.
func (a *AppCore) playwrightCandidates() [][]string {
	dir := a.vkFetcherDir()

	var list [][]string

	if runtime.GOOS == "windows" {
		list = append(list,
			[]string{filepath.Join(dir, "playwright.ps1")},
			[]string{filepath.Join(dir, "playwright.cmd")},
			[]string{filepath.Join(dir, "playwright.exe")},
		)
	} else {
		list = append(list, []string{filepath.Join(dir, "playwright")})
	}

	// Глобальные варианты.
	list = append(list,
		[]string{"playwright"},
		[]string{"dotnet", "playwright"},
	)

	return list
}

// installPlaywrightChromium выполняет `playwright install chromium`.
// Возвращает nil, если браузер успешно установлен (или уже был).
func (a *AppCore) installPlaywrightChromium() error {
	a.AddLog("[VK] Chromium не найден, устанавливаю через Playwright...")

	var lastErr error
	for _, base := range a.playwrightCandidates() {
		args := append(append([]string{}, base[1:]...), "install", "chromium")

		cmd := exec.Command(base[0], args...)
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
			// Кандидат недоступен (нет файла / не в PATH) — пробуем следующий.
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
			a.AddLog(fmt.Sprintf("[VK] Установка Chromium через %q не удалась: %v", base[0], err))
			continue
		}

		a.AddLog("[VK] Chromium успешно установлен")
		return nil
	}

	if lastErr == nil {
		lastErr = fmt.Errorf("playwright CLI не найден")
	}
	return fmt.Errorf("не удалось установить Chromium: %w", lastErr)
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
