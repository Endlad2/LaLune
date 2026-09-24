// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// vkplaywright.go - установка Chromium / Playwright runtime для
// LaLuneTokenFetcher (Playwright).
//
// Алгоритм:
//
//   1. Когда fetcher сообщает LALUNE_CHROMIUM_MISSING (или exit=4):
//      a. Скачиваем свежий LaLuneTokenFetcher_<OS>.zip с
//         github.com/Endlad2/LaLune/releases/latest.
//      b. Распаковываем содержимое ПОВЕРХ <vk-token-fetcher>\ (не удаляя
//         папку целиком — так сохраняются уже скачанные browsers\ и
//         userdata\, если они есть).
//      c. Запускаем ЛОКАЛЬНЫЙ playwright.ps1 / playwright (тот, что лежит
//         рядом с LaLuneTokenFetcher) с аргументами "install chromium".
//
//   2. PLAYWRIGHT_BROWSERS_PATH=<vk-token-fetcher>/browsers выставляется
//      и при установке (installPlaywrightChromium), и при запуске самого
//      fetcher'а (vkfetcher_launch.go) — иначе Playwright ищет Chromium
//      в дефолтном месте и снова падает с тем же маркером.
//
//   3. PLAYWRIGHT_SKIP_BROWSER_GC=1 — чтобы Playwright не удалил только
//      что поставленный Chromium при апдейте.
//
//   4. На Windows playwright.ps1 запускается через `pwsh -File` (PowerShell 7,
//      .NET 8 — совпадает с таргетом Microsoft.Playwright.dll); если pwsh
//      нет — фолбэк на `powershell -File` (Windows PowerShell 5.1).

package libs

import (
	"archive/zip"
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// ChromiumMissingMarker - строка, которую печатает fetcher, когда Playwright
// не инициализирован. Должна совпадать с Program.cs
// (LaLuneTokenFetcher.Playwright).
const ChromiumMissingMarker = "LALUNE_CHROMIUM_MISSING"

// playwrightBrowsersSubdir - имя подпапки внутри vk-token-fetcher, куда
// Playwright кладёт скачанные браузеры (передаётся через
// PLAYWRIGHT_BROWSERS_PATH).
const playwrightBrowsersSubdir = "browsers"

// fetcherArchiveName возвращает имя ZIP-архива fetcher'а для текущей ОС,
// как он опубликован в LaLune releases/latest.
func fetcherArchiveName() string {
	if runtime.GOOS == "windows" {
		return "LaLuneTokenFetcher_Windows.zip"
	}
	return "LaLuneTokenFetcher_Linux.zip"
}

// fetcherArchiveURL - URL последнего релиза архива fetcher'а.
func fetcherArchiveURL() string {
	return "https://github.com/Endlad2/LaLune/releases/latest/download/" + fetcherArchiveName()
}

// playwrightBrowsersPath возвращает полный путь к папке, в которую
// Playwright должен устанавливать браузеры.
//
// Эта же папка выставляется в PLAYWRIGHT_BROWSERS_PATH при запуске
// самого fetcher'а (см. vkfetcher_launch.go), чтобы он нашёл Chromium.
func (a *AppCore) playwrightBrowsersPath() string {
	return filepath.Join(a.vkFetcherDir(), playwrightBrowsersSubdir)
}

// playwrightCommand описывает один способ запуска Playwright CLI: argv[0] -
// исполняемый файл, argv[1:] - уже добавленные аргументы (например, для ps1:
// powershell -File <path>). К ним допишется "install chromium".
type playwrightCommand struct {
	argv []string
	desc string
}

// playwrightCandidates возвращает возможные способы запуска ЛОКАЛЬНОГО
// Playwright CLI, начиная с playwright.ps1 рядом с fetcher'ом.
//
// Порядок на Windows:
//   1. pwsh -File playwright.ps1   — PowerShell 7 (.NET 8), совпадает с
//                                    таргетом Microsoft.Playwright.dll.
//   2. powershell -File playwright.ps1 — Windows PowerShell 5.1. Если
//                                    DLL таргетит net8.0, а система без
//                                    .NET 8 runtime, загрузка упадёт —
//                                    поэтому pwsh идёт первым.
//   3. playwright.cmd / playwright.exe
//   4. playwright из PATH
//   5. dotnet playwright
func (a *AppCore) playwrightCandidates() []playwrightCommand {
	dir := a.vkFetcherDir()

	var list []playwrightCommand

	if runtime.GOOS == "windows" {
		ps1 := filepath.Join(dir, "playwright.ps1")

		// pwsh (PowerShell Core) - основной путь: совпадает с .NET 8.
		list = append(list, playwrightCommand{
			argv: []string{
				"pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass",
				"-File", ps1,
			},
			desc: "pwsh -File playwright.ps1",
		})

		// Windows PowerShell 5.1 - фолбэк.
		list = append(list, playwrightCommand{
			argv: []string{
				"powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
				"-File", ps1,
			},
			desc: "powershell -File playwright.ps1",
		})

		// .cmd / .exe - если вдруг есть.
		list = append(list,
			playwrightCommand{
				argv: []string{filepath.Join(dir, "playwright.cmd")},
				desc: "playwright.cmd",
			},
			playwrightCommand{
				argv: []string{filepath.Join(dir, "playwright.exe")},
				desc: "playwright.exe",
			},
		)
	} else {
		list = append(list, playwrightCommand{
			argv: []string{filepath.Join(dir, "playwright")},
			desc: "playwright (рядом с fetcher'ом)",
		})
	}

	// Глобальные варианты.
	list = append(list,
		playwrightCommand{argv: []string{"playwright"}, desc: "playwright (PATH)"},
		playwrightCommand{argv: []string{"dotnet", "playwright"}, desc: "dotnet playwright"},
	)

	return list
}

// ensurePlaywrightRuntime скачивает свежий LaLuneTokenFetcher_<OS>.zip
// с GitHub releases/latest и распаковывает его содержимое ПОВЕРХ
// <vk-token-fetcher>\. Существующие browsers\ и userdata\ при этом
// НЕ удаляются.
//
// Возвращает nil, если архив скачался и распаковался без ошибок.
// Ошибки сети/скачивания не фатальны: если в папке уже лежит рабочий
// playwright.ps1, installPlaywrightChromium всё равно его попробует.
func (a *AppCore) ensurePlaywrightRuntime() error {
	dir := a.vkFetcherDir()
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("не удалось создать %s: %w", dir, err)
	}

	url := fetcherArchiveURL()
	zipPath := filepath.Join(dir, "fetcher.zip")
	tmpZip := zipPath + ".tmp"

	a.AddLog("[VK] Скачиваю runtime fetcher'а: " + url)

	if !DownloadFile(url, tmpZip) {
		os.Remove(tmpZip)
		return fmt.Errorf("не удалось скачать %s", url)
	}

	// Атомарная подмена.
	_ = os.Remove(zipPath)
	if err := os.Rename(tmpZip, zipPath); err != nil {
		os.Remove(tmpZip)
		return fmt.Errorf("не удалось переименовать %s: %w", tmpZip, err)
	}

	a.AddLog("[VK] Распаковываю runtime в " + dir)
	if err := unzipOverwrite(zipPath, dir); err != nil {
		return fmt.Errorf("не удалось распаковать %s: %w", zipPath, err)
	}

	_ = os.Remove(zipPath)

	if runtime.GOOS != "windows" {
		exe := a.vkFetcherExePath()
		if _, err := os.Stat(exe); err == nil {
			_ = os.Chmod(exe, 0755)
		}
	}

	a.AddLog("[VK] Runtime fetcher'а готов")
	return nil
}

// unzipOverwrite распаковывает zipPath в destDir, перезаписывая
// существующие файлы и НЕ удаляя то, чего нет в архиве (то есть
// browsers\ и userdata\ сохраняются).
func unzipOverwrite(zipPath, destDir string) error {
	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer r.Close()

	for _, f := range r.File {
		// Безопасное имя внутри архива.
		name := strings.ReplaceAll(f.Name, "\\", "/")
		name = strings.TrimPrefix(name, "./")
		name = strings.TrimPrefix(name, "/")
		name = strings.TrimRight(name, "/")
		if name == "" || name == "." {
			continue
		}

		// Если архив содержит вложенную папку vk-token-fetcher/... —
		// срезаем её, чтобы содержимое легло прямо в destDir.
		if strings.HasPrefix(name, "vk-token-fetcher/") {
			name = strings.TrimPrefix(name, "vk-token-fetcher/")
		}
		if name == "" {
			continue
		}

		target := filepath.Join(destDir, filepath.FromSlash(name))

		// Защита от path traversal.
		rel, err := filepath.Rel(destDir, target)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
			return fmt.Errorf("некорректный путь в архиве: %s", f.Name)
		}

		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return fmt.Errorf("mkdir %s: %w", filepath.Dir(target), err)
		}

		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0755); err != nil {
				return fmt.Errorf("mkdir %s: %w", target, err)
			}
			continue
		}

		rc, err := f.Open()
		if err != nil {
			return err
		}

		out, err := os.Create(target)
		if err != nil {
			rc.Close()
			return err
		}

		_, err = io.Copy(out, rc)
		out.Close()
		rc.Close()
		if err != nil {
			return err
		}

		if mode := f.Mode(); mode != 0 {
			_ = os.Chmod(target, mode)
		}
	}

	return nil
}

// installPlaywrightChromium выполняет `playwright install chromium`.
//
// Порядок:
//   1. ensurePlaywrightRuntime() — скачать и распаковать свежий
//      LaLuneTokenFetcher_<OS>.zip поверх <vk-token-fetcher>\.
//   2. Запустить локальный playwright.ps1 / playwright с
//      "install chromium" и PLAYWRIGHT_BROWSERS_PATH=<dir>/browsers.
//
// Возвращает nil, если установка успешно завершилась.
func (a *AppCore) installPlaywrightChromium() error {
	a.AddLog("[VK] Playwright/Chromium не готов, начинаю установку...")

	// Шаг 1: обновить runtime fetcher'а (playwright.ps1, DLL и пр.).
	// Не фатально, если не удалось — возможно, всё уже на месте.
	if err := a.ensurePlaywrightRuntime(); err != nil {
		a.AddLog("[VK] Не удалось обновить runtime fetcher'а: " + err.Error())
		a.AddLog("[VK] Продолжаю с тем, что уже лежит в vk-token-fetcher/")
	}

	browsersPath := a.playwrightBrowsersPath()
	if err := os.MkdirAll(browsersPath, 0755); err != nil {
		a.AddLog(fmt.Sprintf("[VK] Не удалось создать %s: %v", browsersPath, err))
	}
	a.AddLog("[VK] Браузеры будут установлены в: " + browsersPath)

	// Шаг 2: локальный playwright.ps1 install chromium.
	var lastErr error
	for _, cand := range a.playwrightCandidates() {
		// Ключевое: передаём именно "install chromium" как аргументы.
		// Для ps1 это уйдёт в $args и вызовется
		// [Microsoft.Playwright.Program]::Main(["install","chromium"]).
		argv := append(append([]string{}, cand.argv...), "install", "chromium")

		cmd := exec.Command(argv[0], argv[1:]...)
		cmd.Dir = a.vkFetcherDir()

		// PLAYWRIGHT_BROWSERS_PATH - куда ставить браузеры.
		// PLAYWRIGHT_SKIP_BROWSER_GC - не удалять старые версии автоматически.
		cmd.Env = append(os.Environ(),
			"PLAYWRIGHT_BROWSERS_PATH="+browsersPath,
			"PLAYWRIGHT_SKIP_BROWSER_GC=1",
		)

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

		a.AddLog(fmt.Sprintf("[VK] Пробую: %s install chromium", cand.desc))

		if err := cmd.Start(); err != nil {
			lastErr = err
			a.AddLog(fmt.Sprintf("[VK] Кандидат %q недоступен: %v", cand.desc, err))
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
			a.AddLog(fmt.Sprintf("[VK] Установка через %q не удалась: %v", cand.desc, err))
			continue
		}

		// Проверяем, что Chromium реально появился в browsersPath.
		if !dirHasChromium(browsersPath) {
			a.AddLog("[VK] Команда завершилась успешно, но Chromium не найден в " + browsersPath)
			a.AddLog("[VK] Возможно, PLAYWRIGHT_BROWSERS_PATH не подхватился — пробую следующий способ")
			lastErr = fmt.Errorf("Chromium не найден в %s после установки", browsersPath)
			continue
		}

		a.AddLog("[VK] Playwright/Chromium успешно установлен в " + browsersPath)
		return nil
	}

	if lastErr == nil {
		lastErr = fmt.Errorf("playwright CLI не найден")
	}
	return fmt.Errorf("не удалось установить Playwright/Chromium: %w", lastErr)
}

// dirHasChromium проверяет, есть ли в папке хотя бы одна подпапка
// chromium-XXXX (Playwright кладёт браузеры именно так).
func dirHasChromium(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := strings.ToLower(e.Name())
		if strings.HasPrefix(name, "chromium") {
			return true
		}
	}
	return false
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
