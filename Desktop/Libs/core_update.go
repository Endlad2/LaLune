// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

package libs

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// ============================================================
//  Ядра нескольких протоколов (CSQTT, FreeTurn, OlcRTC,
//  OpenFlux, ToTS) — обобщение логики из update.go.
// ============================================================

// CoreVersionFile returns the path of the cached LATEST marker for a protocol.
func (a *AppCore) CoreVersionFile(protocolID string) string {
	return filepath.Join(a.appDir, "LATEST-"+strings.ToUpper(protocolID))
}

// ProtocolCorePath returns the on-disk path of the downloaded core for a protocol.
func (a *AppCore) ProtocolCorePath(protocolID string) string {
	spec, ok := ProtocolByID(protocolID)
	if !ok {
		return filepath.Join(a.appDir, "core-"+strings.ToLower(protocolID))
	}
	return filepath.Join(a.appDir, CurrentCoreAssetName(spec))
}

// FetchLatestForProtocol reads the LATEST marker of the given protocol's repo
// using the same three-level fallback (direct / proxy-browser-UA / proxy-curl-UA)
// that CSQTT already uses.
func (a *AppCore) FetchLatestForProtocol(protocolID string) string {
	spec, ok := ProtocolByID(protocolID)
	if !ok {
		a.AddLog(fmt.Sprintf("[CORE] Неизвестный протокол: %s", protocolID))
		return ""
	}

	attempts := []string{
		spec.LatestURL,
		PROXY_URL + url.QueryEscape(spec.LatestURL),
		PROXY_URL + url.QueryEscape(spec.LatestURL),
	}

	for i, attemptURL := range attempts {
		level := i + 1

		client := &http.Client{Timeout: HTTP_TIMEOUT}
		req, err := http.NewRequest("GET", attemptURL, nil)
		if err != nil {
			continue
		}
		if level == 3 {
			req.Header.Set("User-Agent", "curl/7.68.0")
		} else {
			req.Header.Set("User-Agent", USER_AGENT)
		}

		resp, err := client.Do(req)
		if err != nil {
			continue
		}
		data, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil || resp.StatusCode != 200 {
			continue
		}

		version := strings.TrimSpace(string(data))
		version = strings.ReplaceAll(version, "\r", "")
		version = strings.ReplaceAll(version, "\n", "")
		if version == "" ||
			strings.Contains(version, "Server error") ||
			strings.Contains(version, "No connection adapters") {
			continue
		}

		a.AddLog(fmt.Sprintf("[CORE][%s][LEVEL %d] LATEST=%s", spec.ID, level, version))
		return version
	}

	a.AddLog(fmt.Sprintf("[CORE][%s] Не удалось получить LATEST", spec.ID))
	return ""
}

// DownloadCoreForProtocol downloads the desktop core of any supported protocol.
func (a *AppCore) DownloadCoreForProtocol(protocolID string) bool {
	spec, ok := ProtocolByID(protocolID)
	if !ok {
		a.AddLog(fmt.Sprintf("[CORE] Неизвестный протокол: %s", protocolID))
		return false
	}

	version := a.FetchLatestForProtocol(protocolID)
	if version == "" {
		return false
	}

	asset := CurrentCoreAssetName(spec)
	coreURL := fmt.Sprintf(spec.AssetTemplate, version, asset)
	dest := a.ProtocolCorePath(protocolID)
	tmp := dest + ".tmp"

	a.NotifyCoreDownloading(true)
	defer a.NotifyCoreDownloading(false)

	a.AddLog(fmt.Sprintf("[CORE][%s] Скачивание %s (%s)", spec.ID, asset, version))

	if !a.downloadFile(coreURL, tmp) {
		a.AddLog(fmt.Sprintf("[CORE][%s] Ошибка скачивания", spec.ID))
		os.Remove(tmp)
		return false
	}

	_ = os.Remove(dest)
	if err := os.Rename(tmp, dest); err != nil {
		a.AddLog(fmt.Sprintf("[CORE][%s] Ошибка переименования: %v", spec.ID, err))
		os.Remove(tmp)
		return false
	}

	if runtime.GOOS != "windows" {
		_ = os.Chmod(dest, 0755)
	}

	_ = os.WriteFile(a.CoreVersionFile(protocolID), []byte(version), 0644)
	a.AddLog(fmt.Sprintf("[CORE][%s] Ядро обновлено до %s", spec.ID, version))
	return true
}

// EnsureCoreForProtocol downloads the core only if it is missing or outdated.
func (a *AppCore) EnsureCoreForProtocol(protocolID string) bool {
	spec, ok := ProtocolByID(protocolID)
	if !ok {
		return false
	}

	dest := a.ProtocolCorePath(protocolID)
	if _, err := os.Stat(dest); err != nil {
		return a.DownloadCoreForProtocol(spec.ID)
	}

	remote := a.FetchLatestForProtocol(spec.ID)
	local := ""
	if data, err := os.ReadFile(a.CoreVersionFile(spec.ID)); err == nil {
		local = strings.TrimSpace(string(data))
	}

	if remote != "" && remote != local {
		return a.DownloadCoreForProtocol(spec.ID)
	}
	return true
}

// ListProtocolsJson returns the supported protocol registry as JSON so the
// frontend can render the protocol picker without hardcoding URLs.
func (a *AppCore) ListProtocolsJson() string {
	type entry struct {
		ID          string `json:"id"`
		DisplayName string `json:"displayName"`
		Repo        string `json:"repo"`
		Realtime    bool   `json:"realtime"`
		Description string `json:"description"`
		CoreAsset   string `json:"coreAsset"`
	}

	out := make([]entry, 0, len(SupportedProtocols))
	for _, p := range SupportedProtocols {
		out = append(out, entry{
			ID:          p.ID,
			DisplayName: p.DisplayName,
			Repo:        p.Repo,
			Realtime:    p.Realtime,
			Description: p.Description,
			CoreAsset:   CurrentCoreAssetName(p),
		})
	}
	data, _ := json.Marshal(out)
	return string(data)
}
