package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

// CoreVersionInfo — то, что мы храним между запусками,
// чтобы знать, когда вышло обновление.
type CoreVersionInfo struct {
	// RemoteVersion — то, что вернул LATEST (формат 26.09.11.17.17).
	RemoteVersion string `json:"remoteVersion"`

	// LocalVersion — то, что уже скачано (тоже формат LATEST).
	LocalVersion string `json:"localVersion"`

	// LastCheck — Unix-время последней проверки.
	LastCheck int64 `json:"lastCheck"`
}

// latestFileInCoreDir — файл, куда пишем LocalVersion после успешного скачивания.
const coreVersionFile = CoreDir + "/LATEST"

// FetchLatestVersion возвращает версию с github raw с трёхуровневым fallback
// (как на Desktop/Android): напрямую → через прокси → через прокси с curl UA.
func FetchLatestVersion() (string, error) {
	urls := []string{
		LatestURL,
		ProxyURL + url.QueryEscape(LatestURL),
		ProxyURL + url.QueryEscape(LatestURL),
	}

	client := &http.Client{Timeout: 30 * time.Second}

	for i, u := range urls {
		req, err := http.NewRequest("GET", u, nil)
		if err != nil {
			continue
		}
		if i == 2 {
			req.Header.Set("User-Agent", "curl/7.68.0")
		} else {
			req.Header.Set("User-Agent", UserAgent)
		}

		resp, err := client.Do(req)
		if err != nil {
			continue
		}
		data, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			continue
		}
		if resp.StatusCode != 200 {
			continue
		}
		content := strings.TrimSpace(string(data))
		if content == "" ||
			strings.Contains(content, "Server error") ||
			strings.Contains(content, "No connection adapters") {
			continue
		}
		return content, nil
	}
	return "", fmt.Errorf("не удалось получить LATEST")
}

// LocalVersion возвращает установленную версию ядра (или "" если не скачано).
func LocalVersion() string {
	data, err := os.ReadFile(coreVersionFile)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// CheckForUpdate возвращает (remote, local, hasUpdate).
// local == "" означает «ядро ещё не скачано, версия "-"».
func CheckForUpdate() (string, string, bool, error) {
	remote, err := FetchLatestVersion()
	if err != nil {
		return "", "", false, err
	}
	local := LocalVersion()
	return remote, local, remote != local, nil
}

// DownloadCore скачивает ядро нужной архитектуры во временный файл,
// проверяет ELF-магию, делает исполняемым и атомарно подменяет старое.
func DownloadCore(arch string) error {
	version, err := FetchLatestVersion()
	if err != nil {
		return err
	}

	filename := CoreFilename(arch)
	coreURL := fmt.Sprintf(CoreReleaseURL, version, filename)
	finalPath := CorePath(arch)
	tmpPath := finalPath + ".tmp"

	urls := []string{
		coreURL,
		ProxyURL + url.QueryEscape(coreURL),
		ProxyURL + url.QueryEscape(coreURL),
	}

	client := &http.Client{Timeout: 5 * time.Minute}
	var downloaded bool

	for i, u := range urls {
		req, err := http.NewRequest("GET", u, nil)
		if err != nil {
			continue
		}
		if i == 2 {
			req.Header.Set("User-Agent", "curl/7.68.0")
		} else {
			req.Header.Set("User-Agent", UserAgent)
		}

		resp, err := client.Do(req)
		if err != nil {
			continue
		}
		if resp.StatusCode != 200 {
			resp.Body.Close()
			continue
		}

		f, err := os.Create(tmpPath)
		if err != nil {
			resp.Body.Close()
			return fmt.Errorf("create %s: %w", tmpPath, err)
		}
		_, err = io.Copy(f, resp.Body)
		f.Close()
		resp.Body.Close()
		if err != nil {
			os.Remove(tmpPath)
			continue
		}

		info, err := os.Stat(tmpPath)
		if err != nil || info.Size() < 100_000 {
			os.Remove(tmpPath)
			continue
		}
		downloaded = true
		break
	}

	if !downloaded {
		return fmt.Errorf("не удалось скачать ядро")
	}

	// Проверка ELF-magic: 7F 45 4C 46
	f, err := os.Open(tmpPath)
	if err != nil {
		return err
	}
	magic := make([]byte, 4)
	if _, err := io.ReadFull(f, magic); err != nil {
		f.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("чтение файла ядра: %w", err)
	}
	f.Close()
	if magic[0] != 0x7F || magic[1] != 'E' || magic[2] != 'L' || magic[3] != 'F' {
		os.Remove(tmpPath)
		return fmt.Errorf("скачанный файл не является ELF-бинарником")
	}

	if err := os.Chmod(tmpPath, 0755); err != nil {
		os.Remove(tmpPath)
		return err
	}

	// Атомарная подмена
	if err := os.Rename(tmpPath, finalPath); err != nil {
		os.Remove(tmpPath)
		return err
	}

	// Записываем LocalVersion
	if err := atomicWrite(coreVersionFile, []byte(version), 0644); err != nil {
		return err
	}

	return nil
}

// HasCore проверяет, существует ли ядро для указанной архитектуры.
func HasCore(arch string) bool {
	_, err := os.Stat(CorePath(arch))
	return err == nil
}

// ArchFromRuntime определяет архитектуру из runtime.GOARCH.
// На роутере это arm (armv7) или arm64.
func ArchFromRuntime() string {
	switch runtime.GOARCH {
	case "arm64":
		return "arm64"
	case "arm":
		return "armv7"
	case "mips":
		return "mips"
	case "mipsle":
		return "mipsle"
	case "amd64":
		return "x86_64"
	default:
		return runtime.GOARCH
	}
}

// VersionFileToJSON — для отладки через CLI:
//   lalune -version
// печатает всю инфу о версии.
func VersionFileToJSON() ([]byte, error) {
	remote, err := FetchLatestVersion()
	if err != nil {
		remote = ""
	}
	info := CoreVersionInfo{
		RemoteVersion: remote,
		LocalVersion:  LocalVersion(),
		LastCheck:     time.Now().Unix(),
	}
	return json.MarshalIndent(info, "", "  ")
}

// ensureCoreAtStartup — при старте демона проверяем, есть ли ядро.
// Если нет — не скачиваем автоматически, а ждём «Проверить обновления ядра» из UI.
// Но если файл есть и версия пустая — записываем текущий LATEST как локальный.
func ensureCoreAtStartup() {
	arch := ArchFromRuntime()
	if !HasCore(arch) {
		return
	}
	if LocalVersion() == "" {
		if remote, err := FetchLatestVersion(); err == nil {
			_ = atomicWrite(coreVersionFile, []byte(remote), 0644)
		}
	}
}

// CheckLaLuneUpdate — заглушка для «Проверить обновления LaLune».
// Сейчас возвращает "нет обновлений", чтобы UI не падал.
// TODO: подключить к релизам LaLune, когда будет готово.
func CheckLaLuneUpdate() (string, string, bool) {
	return "0.5.0", "0.5.0", false
}

// execCommand — обёртка для запуска shell-команд с логированием.
// Используется в tun.go для ip/iptables.
func execCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %v: %w (%s)", name, args, err, strings.TrimSpace(string(out)))
	}
	return nil
}
