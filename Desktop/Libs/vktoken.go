// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// vktoken.go — установка/запуск LaLuneTokenFetcher, проверка состояния токена.
// Токен читается/пишется через token.json (единственный источник).

package libs

import (
	"archive/zip"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	VKTokenFetcherDir     = "vk-token-fetcher"
	VKTokenFile           = "token.json"
	VKTokenFetcherArchive = "LaLuneTokenFetcher_%s.zip"
	VKTokenFetcherURLTmpl = "https://github.com/Endlad2/LaLune/releases/latest/download/%s"
	VKTokenFetcherExeWin  = "LaLuneTokenFetcher.exe"
	VKTokenFetcherExeNix  = "LaLuneTokenFetcher"
)

type VKTokenJSON struct {
	Token   string    `json:"Token"`
	SavedAt time.Time `json:"SavedAt"`
}

type VkTokenState struct {
	HasToken  bool   `json:"hasToken"`
	FetcherOK bool   `json:"fetcherOk"`
	Fetching  bool   `json:"fetching"`
	Message   string `json:"message"`
	Progress  int    `json:"progress"`
}

func (a *AppCore) vkFetcherDir() string {
	return filepath.Join(a.appDir, VKTokenFetcherDir)
}

func (a *AppCore) vkTokenFile() string {
	return filepath.Join(a.appDir, VKTokenFile)
}

func (a *AppCore) vkFetcherExePath() string {
	name := VKTokenFetcherExeNix
	if runtime.GOOS == "windows" {
		name = VKTokenFetcherExeWin
	}
	return filepath.Join(a.vkFetcherDir(), name)
}

// HasVKToken — есть ли непустой токен в token.json.
func (a *AppCore) HasVKToken() bool {
	return a.ReadTokenFromFile() != ""
}

// ReadVKTokenRaw — сырое чтение token.json (для диагностики).
func (a *AppCore) ReadVKTokenRaw() (string, error) {
	data, err := os.ReadFile(a.vkTokenFile())
	if err != nil {
		return "", err
	}
	var j VKTokenJSON
	if err := json.Unmarshal(data, &j); err != nil {
		return "", err
	}
	return strings.TrimSpace(j.Token), nil
}

// IsFetcherInstalled — установлен ли LaLuneTokenFetcher.
func (a *AppCore) IsFetcherInstalled() bool {
	exe := a.vkFetcherExePath()
	_, err := os.Stat(exe)
	return err == nil
}

// HasValidVKToken — для UI: есть ли валидный токен.
// Используется в ValidateVKToken и GetVKTokenState.
func (a *AppCore) HasValidVKToken() bool {
	return a.ReadTokenFromFile() != ""
}

// EnsureVKTokenFetcher — скачивает и устанавливает LaLuneTokenFetcher.
func (a *AppCore) EnsureVKTokenFetcher() (bool, error) {
	if a.IsFetcherInstalled() {
		a.AddLog("[VK] Token fetcher уже установлен")
		return true, nil
	}

	osName := "Linux"
	if runtime.GOOS == "windows" {
		osName = "Windows"
	} else if runtime.GOOS == "darwin" {
		return false, fmt.Errorf("VK token fetcher не поддерживается на macOS")
	}

	archiveName := fmt.Sprintf(VKTokenFetcherArchive, osName)
	url := fmt.Sprintf(VKTokenFetcherURLTmpl, archiveName)
	zipPath := filepath.Join(a.appDir, "vk-token-fetcher.zip")

	a.AddLog(fmt.Sprintf("[VK] Скачиваю token fetcher: %s", archiveName))

	if !DownloadFile(url, zipPath) {
		return false, fmt.Errorf("не удалось скачать %s", archiveName)
	}

	if err := unzipInto(zipPath, a.appDir); err != nil {
		os.Remove(zipPath)
		return false, fmt.Errorf("не удалось распаковать: %w", err)
	}
	os.Remove(zipPath)

	if runtime.GOOS != "windows" {
		exe := a.vkFetcherExePath()
		if err := os.Chmod(exe, 0755); err != nil {
			a.AddLog(fmt.Sprintf("[VK] Не удалось сделать файл исполняемым: %v", err))
		}
	}

	if !a.IsFetcherInstalled() {
		return false, fmt.Errorf("бинарник fetcher'а не найден после распаковки")
	}

	a.AddLog("[VK] Token fetcher установлен")
	return true, nil
}

// StartVKTokenFetcher — запускает fetcher и стримит состояние в канал.
func (a *AppCore) StartVKTokenFetcher() <-chan VkTokenState {
	ch := make(chan VkTokenState, 16)

	go func() {
		defer close(ch)

		send := func(s VkTokenState) {
			select {
			case ch <- s:
			default:
			}
		}

		if a.HasVKToken() {
			send(VkTokenState{
				HasToken:  true,
				FetcherOK: a.IsFetcherInstalled(),
				Message:   "Токен ВК уже получен",
				Progress:  100,
			})
			return
		}

		if !a.IsFetcherInstalled() {
			send(VkTokenState{
				Fetching: true,
				Message:  "Пакет LaLuneTokenFetcher не найден, начинаю скачивание...",
				Progress: 5,
			})

			ok, err := a.EnsureVKTokenFetcher()
			if !ok {
				msg := "Ошибка установки LaLuneTokenFetcher"
				if err != nil {
					msg = msg + ": " + err.Error()
				}
				send(VkTokenState{Message: msg})
				return
			}

			send(VkTokenState{
				FetcherOK: true,
				Fetching:  true,
				Message:   "Пакет LaLuneTokenFetcher установлен",
				Progress:  30,
			})
		}

		_ = os.Remove(a.vkTokenFile())

		send(VkTokenState{
			FetcherOK: true,
			Fetching:  true,
			Message:   "Открываю окно авторизации ВК...",
			Progress:  40,
		})

		exe := a.vkFetcherExePath()
		cmd := exec.Command(exe)
		cmd.Dir = a.vkFetcherDir()
		if err := cmd.Start(); err != nil {
			send(VkTokenState{
				FetcherOK: true,
				Message:   "Не удалось запустить LaLuneTokenFetcher: " + err.Error(),
			})
			return
		}

		a.AddLog(fmt.Sprintf("[VK] Token fetcher запущен (PID: %d)", cmd.Process.Pid))

		deadline := time.Now().Add(10 * time.Minute)
		progress := 40
		tick := 0

		for time.Now().Before(deadline) {
			if _, err := os.Stat(a.vkTokenFile()); err == nil {
				token := a.ReadTokenFromFile()
				if token != "" {
					send(VkTokenState{
						HasToken:  true,
						FetcherOK: true,
						Message:   "Поздравляем, токен ВК получен успешно",
						Progress:  100,
					})
					return
				}
			}

			tick++
			if progress < 90 && tick%6 == 0 {
				progress += 5
			}

			send(VkTokenState{
				FetcherOK: true,
				Fetching:  true,
				Message:   "Ожидание авторизации в ВК...",
				Progress:  progress,
			})

			time.Sleep(500 * time.Millisecond)
		}

		send(VkTokenState{
			FetcherOK: true,
			Message:   "Время ожидания истекло. Попробуйте войти снова",
		})
	}()

	return ch
}

// DeleteVKToken — удаляет token.json.
func (a *AppCore) DeleteVKToken() bool {
	_ = os.Remove(a.vkTokenFile())
	a.AddLog("[VK] Токен удалён")
	return true
}

// GetVKTokenState — публичный JS-биндинг: JSON состояния токена.
func (a *AppCore) GetVKTokenState() VkTokenState {
	return VkTokenState{
		HasToken:  a.HasVKToken(),
		FetcherOK: a.IsFetcherInstalled(),
		Fetching:  false,
		Message:   "",
		Progress:  0,
	}
}

// ValidateVKToken — проверяет token.json и возвращает состояние.
func (a *AppCore) ValidateVKToken() VkTokenState {
	return VkTokenState{
		HasToken:  a.HasVKToken(),
		FetcherOK: a.IsFetcherInstalled(),
		Fetching:  false,
		Message:   "",
		Progress:  0,
	}
}

func unzipInto(zipPath, destDir string) error {
	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer r.Close()

	for _, f := range r.File {
		target := filepath.Join(destDir, f.Name)
		rel, err := filepath.Rel(destDir, target)
		if err != nil || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) || rel == ".." {
			return fmt.Errorf("недопустимый путь в архиве: %s", f.Name)
		}

		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0755); err != nil {
				return err
			}
			continue
		}

		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
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
