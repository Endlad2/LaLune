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
	"time"
)

// ============================================================
//  LATEST-версия ядра CSQTT
// ============================================================

// CheckUpdateBackground — фоновая проверка обновлений ядра.
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
		fmt.Printf("[UPDATE] Доступна новая версия ядра: %s\n", remoteVersion)
		if a.updateCallback != nil {
			a.updateCallback(remoteVersion)
		}
	}
}

// CheckUpdateSync — синхронная проверка обновлений ядра.
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

// FetchLatestVersion — читает LATEST с GitHub через трёхуровневый fallback:
//   1. Прямой запрос к raw.githubusercontent.com (браузерный UA)
//   2. Через прокси-сервер 31.77.148.203 (браузерный UA)
//   3. Через тот же прокси, но с curl UA (на случай WAF)
func (a *AppCore) FetchLatestVersion() string {
	urls := []string{
		LATEST_URL,
		PROXY_URL + url.QueryEscape(LATEST_URL),
		PROXY_URL + url.QueryEscape(LATEST_URL),
	}

	for i, attemptURL := range urls {
		level := i + 1
		fmt.Printf("[NET][LEVEL %d] Пробую: %s\n", level, truncateURL(attemptURL, 100))

		client := &http.Client{Timeout: HTTP_TIMEOUT}
		req, err := http.NewRequest("GET", attemptURL, nil)
		if err != nil {
			fmt.Printf("[NET][LEVEL %d] Ошибка запроса: %v\n", level, err)
			continue
		}

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
			fmt.Printf("[NET][LEVEL %d] Ошибка чтения: %v\n", level, err)
			continue
		}

		if resp.StatusCode != 200 {
			fmt.Printf("[NET][LEVEL %d] HTTP %d\n", level, resp.StatusCode)
			continue
		}

		version := strings.TrimSpace(string(data))
		version = strings.ReplaceAll(version, "\n", "")
		version = strings.ReplaceAll(version, "\r", "")

		if version == "" ||
			strings.Contains(version, "Server error") ||
			strings.Contains(version, "No connection adapters") ||
			strings.Contains(version, "curl error") {
			fmt.Printf("[NET][LEVEL %d] Серверная ошибка\n", level)
			continue
		}

		fmt.Printf("[NET][LEVEL %d] УСПЕХ: %s\n", level, version)
		return version
	}

	return ""
}

// ============================================================
//  Обновление ядра CSQTT
// ============================================================

// UpdateCoreWorker — фоновая задача обновления ядра.
func (a *AppCore) UpdateCoreWorker() {
	remoteVersion := a.FetchLatestVersion()
	if remoteVersion == "" {
		a.AddLog("[UPDATE] Не удалось проверить версию ядра")
		return
	}
	a.PerformUpdate(remoteVersion)
}

// PerformUpdate — скачивает ядро нужной версии с трёхуровневым fallback.
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

	if !a.downloadFile(coreURL, tempCore) {
		a.AddLog("[UPDATE] Ошибка скачивания ядра")
		os.Remove(tempCore)
		return
	}

	if _, err := os.Stat(a.corePath); err == nil {
		os.Remove(a.corePath)
	}
	if err := os.Rename(tempCore, a.corePath); err != nil {
		a.AddLog(fmt.Sprintf("[UPDATE] Ошибка переименования: %v", err))
		os.Remove(tempCore)
		return
	}

	if runtime.GOOS != "windows" {
		os.Chmod(a.corePath, 0755)
	}

	os.WriteFile(a.latestFile, []byte(version), 0644)
	a.AddLog(fmt.Sprintf("[UPDATE] Ядро обновлено до версии %s", version))
}

// downloadFile — трёхуровневый fallback для скачивания бинарника:
//   1. Прямой запрос
//   2. Через прокси (браузерный UA)
//   3. Через прокси (curl UA)
func (a *AppCore) downloadFile(rawURL string, destination string) bool {
	urls := []string{
		rawURL,
		PROXY_URL + url.QueryEscape(rawURL),
		PROXY_URL + url.QueryEscape(rawURL),
	}

	for i, attemptURL := range urls {
		level := i + 1
		fmt.Printf("[DOWNLOAD][LEVEL %d] Пробую: %s\n", level, truncateURL(attemptURL, 100))

		client := &http.Client{Timeout: HTTP_TIMEOUT}
		req, err := http.NewRequest("GET", attemptURL, nil)
		if err != nil {
			fmt.Printf("[DOWNLOAD][LEVEL %d] Ошибка запроса: %v\n", level, err)
			continue
		}

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
			fmt.Printf("[DOWNLOAD][LEVEL %d] Ошибка создания файла: %v\n", level, err)
			continue
		}

		_, err = io.Copy(file, resp.Body)
		file.Close()
		resp.Body.Close()

		if err != nil {
			os.Remove(destination)
			fmt.Printf("[DOWNLOAD][LEVEL %d] Ошибка записи: %v\n", level, err)
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

// UpdateCore — публичный метод для UI.
func (a *AppCore) UpdateCore() bool {
	if a.IsConnected() {
		a.AddLog("[UPDATE] Сначала отключитесь")
		return false
	}
	go a.UpdateCoreWorker()
	return true
}

// ============================================================
//  Обновление LaLune
// ============================================================

// LaLuneReleasesURL — страница со всеми релизами LaLune.
// UI открывает её в браузере, когда пользователь согласен обновиться.
const LaLuneReleasesURL = "https://github.com/Endlad2/LaLune/releases/latest"

// LaLuneAPILatest — URL GitHub API для получения последнего релиза.
// Используем API, а не парсинг HTML, потому что API отдаёт чистый JSON.
const LaLuneAPILatest = "https://api.github.com/repos/Endlad2/LaLune/releases/latest"

// CheckLaLuneUpdate — проверяет актуальную версию LaLune через GitHub API.
// Возвращает:
//   - remoteTag:    тег последнего релиза (например "v0.5.0")
//   - hasUpdate:    true, если локальная версия отличается
//   - err:          ошибка сети/парсинга
//
// Трёхуровневый fallback — тот же, что и у ядра:
//   1. Прямой запрос к api.github.com
//   2. Через прокси
//   3. Через прокси с curl UA
func (a *AppCore) CheckLaLuneUpdate() (remoteTag string, hasUpdate bool, err error) {
	remoteTag, err = a.fetchLaLuneLatestTag()
	if err != nil {
		return "", false, err
	}

	localVersion := LaLuneVersion
	if remoteTag != localVersion && remoteTag != "" {
		return remoteTag, true, nil
	}

	return remoteTag, false, nil
}

// fetchLaLuneLatestTag — запрашивает GitHub API, парсит JSON, вытаскивает tag_name.
// Использует те же три уровня fallback, что и FetchLatestVersion.
func (a *AppCore) fetchLaLuneLatestTag() (string, error) {
	urls := []string{
		LaLuneAPILatest,
		PROXY_URL + url.QueryEscape(LaLuneAPILatest),
		PROXY_URL + url.QueryEscape(LaLuneAPILatest),
	}

	for i, attemptURL := range urls {
		level := i + 1
		fmt.Printf("[LALUNE][LEVEL %d] Проверяю: %s\n", level, truncateURL(attemptURL, 100))

		client := &http.Client{Timeout: HTTP_TIMEOUT}
		req, err := http.NewRequest("GET", attemptURL, nil)
		if err != nil {
			fmt.Printf("[LALUNE][LEVEL %d] Ошибка запроса: %v\n", level, err)
			continue
		}

		if level == 3 {
			req.Header.Set("User-Agent", "curl/7.68.0")
		} else {
			req.Header.Set("User-Agent", USER_AGENT)
		}
		req.Header.Set("Accept", "application/vnd.github+json")

		resp, err := client.Do(req)
		if err != nil {
			fmt.Printf("[LALUNE][LEVEL %d] Ошибка: %v\n", level, err)
			continue
		}

		data, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			fmt.Printf("[LALUNE][LEVEL %d] Ошибка чтения: %v\n", level, err)
			continue
		}

		if resp.StatusCode != 200 {
			fmt.Printf("[LALUNE][LEVEL %d] HTTP %d\n", level, resp.StatusCode)
			continue
		}

		// Парсим tag_name из JSON-ответа GitHub API.
		// Простой ручной парсер, чтобы не тянуть encoding/json ради одного поля.
		tag := extractTagName(string(data))
		if tag == "" {
			fmt.Printf("[LALUNE][LEVEL %d] tag_name не найден\n", level)
			continue
		}

		fmt.Printf("[LALUNE][LEVEL %d] УСПЕХ: %s\n", level, tag)
		return tag, nil
	}

	return "", fmt.Errorf("не удалось проверить обновление LaLune")
}

// extractTagName — грубый парсер "tag_name":"v1.2.3" из JSON-ответа GitHub.
// Специально не используем json.Unmarshal, чтобы не тянуть зависимости.
func extractTagName(jsonStr string) string {
	const key = `"tag_name"`
	idx := strings.Index(jsonStr, key)
	if idx < 0 {
		return ""
	}
	rest := jsonStr[idx+len(key):]
	colon := strings.Index(rest, ":")
	if colon < 0 {
		return ""
	}
	rest = rest[colon+1:]
	// пропускаем пробелы и кавычки
	rest = strings.TrimLeft(rest, " \t\r\n")
	if len(rest) == 0 || rest[0] != '"' {
		return ""
	}
	rest = rest[1:]
	end := strings.Index(rest, `"`)
	if end < 0 {
		return ""
	}
	return rest[:end]
}

// OpenLaLuneReleasesURL — возвращает URL страницы релизов.
// UI откроет его в системном браузере, когда пользователь согласится.
func (a *AppCore) OpenLaLuneReleasesURL() string {
	return LaLuneReleasesURL
}

// ============================================================
//  Вспомогательные функции
// ============================================================

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
