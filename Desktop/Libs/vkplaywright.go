// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// vkplaywright.go - установка Chromium / Playwright driver для
// LaLuneTokenFetcher (Playwright).
//
// Если LaLuneTokenFetcher сообщает, что Playwright не инициализирован
// (маркер LALUNE_CHROMIUM_MISSING в выводе или код возврата 4) - это может
// быть либо отсутствующий Chromium, либо отсутствующий Playwright driver
// (node.exe). Обе проблемы решает один и тот же установщик, поставляемый
// вместе с Microsoft.Playwright:
//
//     playwright.ps1 install chromium      (локально рядом с fetcher'ом)
//     playwright     install chromium      (Linux)
//
// НО на Windows надёжнее и проще использовать готовый one-command
// скрипт с GitHub, который сам скачает актуальный LaLuneTokenFetcher.zip,
// распакует во временную папку, загрузит Microsoft.Playwright.dll из
// памяти и вызовет [Microsoft.Playwright.Program]::Main(@("install","chromium")):
//
//     powershell -NoProfile -ExecutionPolicy Bypass -Command `
//         "irm https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/win_install_chromium.ps1 | iex"
//
// Ключевые моменты:
//
//  1) Chromium по умолчанию ставится в глобальный
//     %USERPROFILE%\AppData\Local\ms-playwright. Мы этого не хотим: браузер
//     должен лежать РЯДОМ с fetcher'ом, в подпапке vk-token-fetcher/browsers,
//     чтобы можно было удалить всё одной папкой и не мусорить в профиле юзера.
//     Для этого выставляем PLAYWRIGHT_BROWSERS_PATH=<vk-token-fetcher>/browsers
//     в родительском процессе Go: дочерний powershell унаследует его через
//     os.Environ(), а `iex` подхватит из $Env: уже внутри своего процесса.
//
//  2) Скрипт самодостаточен: тянет ZIP с GitHub releases/latest, находит
//     Microsoft.Playwright.dll в распакованном дереве, грузит его в память
//     и вызывает Program.Main с "install chromium". Нам не нужно знать,
//     куда именно CI положил DLL внутри архива.
//
//  3) На Windows этот путь пробуется ПЕРВЫМ. Если powershell-команда
//     недоступна (нет pwsh/powershell, или GitHub заблокирован) — падаем
//     на старые фолбэки: локальный playwright.ps1 рядом с fetcher'ом,
//     playwright.cmd/.exe, playwright из PATH, dotnet playwright.
//
//  4) Сам playwright.ps1 использует $PSScriptRoot, поэтому путь к .dll
//     находится корректно независимо от cmd.Dir.

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

// playwrightBrowsersSubdir - имя подпапки внутри vk-token-fetcher, куда
// Playwright кладёт скачанные браузеры (передаётся через
// PLAYWRIGHT_BROWSERS_PATH).
const playwrightBrowsersSubdir = "browsers"

// winInstallChromiumURL - one-command install-скрипт с GitHub.
// Сам скачивает LaLuneTokenFetcher_Windows.zip, распаковывает во временную
// папку, грузит Microsoft.Playwright.dll из памяти и запускает
// Program.Main(@("install","chromium")).
const winInstallChromiumURL = "https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/win_install_chromium.ps1"

// playwrightBrowsersPath возвращает полный путь к папке, в которую
// Playwright должен устанавливать браузеры.
//
// Эта же папка выставляется в PLAYWRIGHT_BROWSERS_PATH при запуске
// самого fetcher'а (см. vkfetcher_launch.go), чтобы он нашёл Chromium.
func (a *AppCore) playwrightBrowsersPath() string {
	return filepath.Join(a.vkFetcherDir(), playwrightBrowsersSubdir)
}

// playwrightCommand описывает один способ запуска Playwright CLI: argv[0] -
// исполняемый файл, argv[1:] - уже добавленные аргументы. К ним допишется
// "install chromium" (для one-command скрипта аргументы НЕ дописываются -
// они уже внутри).
type playwrightCommand struct {
	argv   []string
	desc   string
	isRaw  bool // true - argv уже полная команда, не дописывать "install chromium"
}

// playwrightCandidates возвращает возможные способы запуска Playwright CLI,
// начиная с one-command скрипта с GitHub на Windows.
//
// Порядок на Windows:
//  1. powershell -Command "irm ... | iex"   — one-command, тянет свежий ZIP
//     с GitHub и сам вызывает Program.Main(["install","chromium"]).
//  2. pwsh -File playwright.ps1 install chromium  — локальный фолбэк.
//  3. powershell -File playwright.ps1 install chromium — локальный фолбэк.
//  4. playwright.cmd / playwright.exe из папки vk-token-fetcher.
//  5. playwright из PATH.
//  6. dotnet playwright.
func (a *AppCore) playwrightCandidates() []playwrightCommand {
	dir := a.vkFetcherDir()

	var list []playwrightCommand

	if runtime.GOOS == "windows" {
		// --- 1) One-command install с GitHub (предпочтительно) ---
		// Передаём аргументы через -Command, а не -File, потому что сам
		// скрипт тянется по irm|iex. Никаких "install chromium" тут
		// дописывать не надо: они уже дефолт внутри скрипта.
		oneLiner := fmt.Sprintf(
			"irm %s | iex",
			winInstallChromiumURL,
		)
		list = append(list, playwrightCommand{
			argv: []string{
				"powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
				"-Command", oneLiner,
			},
			desc:  "one-command install (irm win_install_chromium.ps1 | iex)",
			isRaw: true,
		})

		// --- 2) Локальный playwright.ps1, если one-command недоступен ---
		ps1 := filepath.Join(dir, "playwright.ps1")

		// pwsh (PowerShell Core) — совпадает с таргетом .NET 8.
		list = append(list, playwrightCommand{
			argv: []string{
				"pwsh", "-NoProfile", "-ExecutionPolicy", "Bypass",
				"-File", ps1,
			},
			desc: "pwsh -File playwright.ps1",
		})

		// Windows PowerShell 5.1 — фолбэк.
		list = append(list, playwrightCommand{
			argv: []string{
				"powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
				"-File", ps1,
			},
			desc: "powershell -File playwright.ps1",
		})

		// .cmd / .exe — если вдруг есть.
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

// installPlaywrightChromium выполняет `playwright install chromium`.
// Это устанавливает и Playwright driver (node), и браузер Chromium.
//
// Chromium ставится в <vk-token-fetcher>/browsers через
// PLAYWRIGHT_BROWSERS_PATH, а не в глобальный ms-playwright.
//
// Возвращает nil, если установка успешно завершилась.
func (a *AppCore) installPlaywrightChromium() error {
	a.AddLog("[VK] Playwright/Chromium не готов, устанавливаю через Playwright...")

	browsersPath := a.playwrightBrowsersPath()
	if err := os.MkdirAll(browsersPath, 0755); err != nil {
		a.AddLog(fmt.Sprintf("[VK] Не удалось создать %s: %v", browsersPath, err))
		// Не фатально - playwright создаст сам.
	}
	a.AddLog("[VK] Браузеры будут установлены в: " + browsersPath)

	var lastErr error
	for _, cand := range a.playwrightCandidates() {
		var argv []string

		if cand.isRaw {
			// One-command: команда уже полная, аргументы внутри неё.
			argv = append([]string{}, cand.argv...)
		} else {
			// Ключевое: передаём именно "install chromium" как аргументы.
			// Для ps1 это уйдёт в $args и вызовется
			// [Microsoft.Playwright.Program]::Main(["install","chromium"]).
			argv = append(append([]string{}, cand.argv...), "install", "chromium")
		}

		cmd := exec.Command(argv[0], argv[1:]...)
		cmd.Dir = a.vkFetcherDir()

		// PLAYWRIGHT_BROWSERS_PATH - куда ставить браузеры.
		// PLAYWRIGHT_SKIP_BROWSER_GC - не удалять старые версии автоматически
		// (иначе может снести только что поставленный Chromium при апдейте).
		//
		// Для one-command скрипта переменные окружения подхватятся
		// внутри powershell: $Env:PLAYWRIGHT_BROWSERS_PATH унаследуется
		// дочерним процессом, а Program.Main установит Chromium туда же.
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

		a.AddLog(fmt.Sprintf("[VK] Пробую: %s", cand.desc))

		if err := cmd.Start(); err != nil {
			// Кандидат недоступен (нет файла / не в PATH) - пробуем следующий.
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

		a.AddLog("[VK] Playwright/Chromium успешно установлен в " + browsersPath)
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
