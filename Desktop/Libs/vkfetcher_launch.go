// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// vkfetcher_launch.go - запуск LaLuneTokenFetcher с перехватом вывода и
// автоматической установкой Chromium.
//
// Запускаем fetcher, читаем stdout+stderr и код возврата. Если он сообщил,
// что Chromium не установлен (код 4 или маркер LALUNE_CHROMIUM_MISSING),
// запускаем `playwright install chromium` и один раз перезапускаем fetcher.
// Дополнительно держим атомарный флаг "процесс жив", чтобы UI не показывал
// бесконечное "Ожидание авторизации", когда fetcher уже завершился.
//
// ВАЖНО: при запуске fetcher'а выставляем PLAYWRIGHT_BROWSERS_PATH в ту же
// папку, куда installPlaywrightChromium() ставит браузеры
// (<vk-token-fetcher>/browsers). Иначе Playwright ищет Chromium в глобальном
// %USERPROFILE%\AppData\Local\ms-playwright и снова падает с тем же маркером.

package libs

import (
	"bytes"
	"os"
	"os/exec"
	"sync"
	"sync/atomic"
)

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

// startFetcherCaptured запускает fetcher, перенаправляя stdout+stderr в буфер.
//
// Ключевой момент: выставляем PLAYWRIGHT_BROWSERS_PATH, чтобы fetcher нашёл
// Chromium, установленный в <vk-token-fetcher>/browsers.
func (a *AppCore) startFetcherCaptured() (*fetcherRun, error) {
	exe := a.vkFetcherExePath()

	cmd := exec.Command(exe)
	cmd.Dir = a.vkFetcherDir()

	// Тот же путь, что и в installPlaywrightChromium().
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

// runFetcherWithFallback запускает fetcher (не блокируя вызывающую горутину) и
// в фоне следит за результатом: при отсутствии Chromium ставит его и
// перезапускает fetcher один раз.
func (a *AppCore) runFetcherWithFallback() error {
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
