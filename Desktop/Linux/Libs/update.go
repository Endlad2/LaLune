package libs

import (
	"archive/zip"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

func (a *AppCore) CheckUpdateBackground() {
	remoteVersion := a.FetchLatestVersion()
	if remoteVersion == "" {
		return
	}

	localVersion := ""
	if data, err := os.ReadFile(a.latestFile); err == nil {
		localVersion = strings.TrimSpace(string(data))
	}

	if remoteVersion != localVersion {
		fmt.Printf("[UPDATE] Доступна новая версия: %s\n", remoteVersion)
		if a.updateCallback != nil {
			a.updateCallback(remoteVersion)
		}
	}
}

func (a *AppCore) CheckUpdateSync() (string, bool, error) {
	remoteVersion := a.FetchLatestVersion()
	if remoteVersion == "" {
		return "", false, fmt.Errorf("не удалось проверить обновления")
	}

	localVersion := ""
	if data, err := os.ReadFile(a.latestFile); err == nil {
		localVersion = strings.TrimSpace(string(data))
	}

	if remoteVersion != localVersion {
		return remoteVersion, true, nil
	}

	return remoteVersion, false, nil
}

func (a *AppCore) FetchLatestVersion() string {
	data := FetchURL(LATEST_URL)
	if data == nil {
		return ""
	}

	version := strings.TrimSpace(string(data))
	version = strings.ReplaceAll(version, "\n", "")
	version = strings.ReplaceAll(version, "\r", "")

	if version == "" ||
		strings.Contains(version, "Server error") ||
		strings.Contains(version, "No connection adapters") ||
		strings.Contains(version, "curl error") {
		return ""
	}

	return version
}

func (a *AppCore) UpdateCoreWorker() {
	remoteVersion := a.FetchLatestVersion()
	if remoteVersion == "" {
		a.AddLog("[UPDATE] Не удалось проверить версию")
		return
	}
	a.PerformUpdate(remoteVersion)
}

func (a *AppCore) PerformUpdate(version string) {
	if a.isDownloading {
		return
	}

	a.isDownloading = true
	defer func() { a.isDownloading = false }()

	version = strings.TrimSpace(version)
	a.AddLog(fmt.Sprintf("[UPDATE] Скачивание ядра версии %s...", version))

	coreURL := fmt.Sprintf(CORE_URL_TEMPLATE, version, a.GetCoreFilename())
	tempCore := a.corePath + ".tmp"

	if !DownloadFile(coreURL, tempCore) {
		a.AddLog("[UPDATE] Ошибка скачивания ядра")
		os.Remove(tempCore)
		return
	}

	if _, err := os.Stat(a.corePath); err == nil {
		os.Remove(a.corePath)
	}
	os.Rename(tempCore, a.corePath)

	if runtime.GOOS != "windows" {
		os.Chmod(a.corePath, 0755)
	}

	os.WriteFile(a.latestFile, []byte(version), 0644)

	a.AddLog(fmt.Sprintf("[UPDATE] Ядро обновлено до версии %s", version))
}

func (a *AppCore) UpdateCore() bool {
	if a.IsConnected() {
		a.AddLog("[UPDATE] Сначала отключитесь")
		return false
	}

	go a.UpdateCoreWorker()
	return true
}

func FetchURL(urlStr string) []byte {
	urlStr = strings.TrimSpace(urlStr)

	urls := []string{
		urlStr,
		PROXY_URL + url.QueryEscape(urlStr),
		PROXY_URL + url.QueryEscape(urlStr),
	}

	for i, attemptURL := range urls {
		level := i + 1
		fmt.Printf("[NET][LEVEL %d] Пробую: %s...\n", level, truncateURL(attemptURL, 100))

		client := &http.Client{Timeout: HTTP_TIMEOUT}
		req, _ := http.NewRequest("GET", attemptURL, nil)

		if level == 3 {
			req.Header.Set("User-Agent", "curl/7.68.0")
		} else {
			req.Header.Set("User-Agent", USER_AGENT)
		}

		resp, err := client.Do(req)
		if err != nil {
			fmt.Printf("[NET][LEVEL %d] Ошибка: %v\n", level, err)
			continue
		}

		data, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			continue
		}

		if resp.StatusCode != 200 {
			fmt.Printf("[NET][LEVEL %d] HTTP %d\n", level, resp.StatusCode)
			continue
		}

		content := string(data)
		if strings.Contains(content, "No connection adapters") ||
			strings.Contains(content, "Server error") {
			fmt.Printf("[NET][LEVEL %d] Серверная ошибка\n", level)
			continue
		}

		fmt.Printf("[NET][LEVEL %d] УСПЕХ (%d байт)\n", level, len(data))
		return data
	}

	return nil
}

func DownloadFile(urlStr string, destination string) bool {
	urlStr = strings.TrimSpace(urlStr)

	urls := []string{
		urlStr,
		PROXY_URL + url.QueryEscape(urlStr),
		PROXY_URL + url.QueryEscape(urlStr),
	}

	for i, attemptURL := range urls {
		level := i + 1
		fmt.Printf("[DOWNLOAD][LEVEL %d] Пробую: %s...\n", level, truncateURL(attemptURL, 100))

		client := &http.Client{Timeout: HTTP_TIMEOUT}
		req, _ := http.NewRequest("GET", attemptURL, nil)

		if level == 3 {
			req.Header.Set("User-Agent", "curl/7.68.0")
		} else {
			req.Header.Set("User-Agent", USER_AGENT)
		}

		resp, err := client.Do(req)
		if err != nil {
			fmt.Printf("[DOWNLOAD][LEVEL %d] Ошибка: %v\n", level, err)
			continue
		}

		if resp.StatusCode != 200 {
			resp.Body.Close()
			fmt.Printf("[DOWNLOAD][LEVEL %d] HTTP %d\n", level, resp.StatusCode)
			continue
		}

		file, err := os.Create(destination)
		if err != nil {
			resp.Body.Close()
			continue
		}

		_, err = io.Copy(file, resp.Body)
		file.Close()
		resp.Body.Close()

		if err != nil {
			os.Remove(destination)
			continue
		}

		info, err := os.Stat(destination)
		if err != nil || info.Size() < 1024 {
			os.Remove(destination)
			fmt.Printf("[DOWNLOAD][LEVEL %d] Файл слишком маленький\n", level)
			continue
		}

		fmt.Printf("[DOWNLOAD][LEVEL %d] УСПЕХ (%d байт)\n", level, info.Size())
		return true
	}

	return false
}

func DownloadAndExtractWintun(appDir string) (string, error) {
	zipPath := filepath.Join(appDir, "wintun.zip")
	dllPath := filepath.Join(appDir, "wintun.dll")

	if _, err := os.Stat(dllPath); err == nil {
		return dllPath, nil
	}

	fmt.Println("[WINTUN] Скачивание wintun.zip...")

	success := DownloadFile(WINTUN_URL, zipPath)
	if !success {
		fmt.Println("[WINTUN] Прямая загрузка не удалась, пробую через прокси...")
		success = DownloadFile(WINTUN_FALLBACK_URL, zipPath)
	}

	if !success {
		return "", fmt.Errorf("не удалось скачать wintun.dll")
	}

	fmt.Println("[WINTUN] Распаковка...")

	reader, err := zip.OpenReader(zipPath)
	if err != nil {
		os.Remove(zipPath)
		return "", fmt.Errorf("ошибка открытия zip: %v", err)
	}
	defer reader.Close()

	var found bool
	for _, file := range reader.File {
		if strings.HasSuffix(file.Name, "wintun.dll") {
			dst, err := os.Create(dllPath)
			if err != nil {
				continue
			}
			defer dst.Close()

			src, err := file.Open()
			if err != nil {
				dst.Close()
				continue
			}
			defer src.Close()

			_, err = io.Copy(dst, src)
			if err != nil {
				dst.Close()
				continue
			}

			found = true
			fmt.Println("[WINTUN] wintun.dll успешно извлечен")
			break
		}
	}

	os.Remove(zipPath)

	if !found {
		return "", fmt.Errorf("wintun.dll не найден в архиве")
	}

	if _, err := os.Stat(dllPath); err != nil {
		return "", fmt.Errorf("wintun.dll не создан: %v", err)
	}

	return dllPath, nil
}

func GetFreePort() int {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 9000
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func truncateURL(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
