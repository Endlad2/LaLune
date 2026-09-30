// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// vkcalls.go — тонкие обёртки над VkAutoCallsManager (см. vk_api.go).
// Здесь только методы AppCore, которые дергает UI через Wails-биндинги.
//
// ВАЖНО: токен берётся ТОЛЬКО из token.json (ReadTokenFromFile).
// settings.VkJsToken не используется нигде в новой логике.

package libs

import (
	"fmt"
	"strings"
)

// ============================================================
//  Публичные обёртки для AppCore (используются UI-биндингами)
// ============================================================

// RunVkAutoApiCalls — берёт токен из token.json, создаёт звонки.
// Количество звонков = ceil(workers / autoApiWorkers).
func (a *AppCore) RunVkAutoApiCalls(onLog func(string)) ([]string, []string, error) {
	token := a.ReadTokenFromFile()
	if token == "" {
		return nil, nil, fmt.Errorf("токен ВК не найден в token.json — выполните вход заново")
	}

	settings := a.GetSettings()
	workers := settings.Workers
	if workers < MinWorkers {
		workers = DefaultWorkers
	}

	autoApiWorkers := settings.AutoApiWorkers
	if autoApiWorkers < MinAutoApiWorkers {
		autoApiWorkers = DefaultAutoApiWorkers
	}

	mgr := NewVkAutoCallsManager()
	defer mgr.Close()

	batch := mgr.CreateForWorkers(token, workers, autoApiWorkers, nil, onLog)
	if batch == nil {
		if mgr.TokenInvalidSeen() {
			a.DeleteVKToken()
			return nil, nil, fmt.Errorf("токен ВК недействителен — выполните вход заново")
		}
		return nil, nil, fmt.Errorf("не удалось создать звонки VK")
	}

	return batch.Hashes(), batch.CallIds(), nil
}

// GetVKToken — алиас на ReadTokenFromFile (для совместимости).
func (a *AppCore) GetVKToken() string {
	return a.ReadTokenFromFile()
}

// FinishVkCalls — завершает указанные звонки. Используется при disconnect.
func (a *AppCore) FinishVkCalls(callIds []string) {
	token := a.ReadTokenFromFile()
	if token == "" || len(callIds) == 0 {
		return
	}
	mgr := NewVkAutoCallsManager()
	mgr.FinishAll(token, callIds, func(s string) { a.AddLog(s) })
	mgr.Close()
}

// ============================================================
//  Утилиты
// ============================================================

func numFromAny(v interface{}) float64 {
	switch x := v.(type) {
	case float64:
		return x
	case int:
		return float64(x)
	case int64:
		return float64(x)
	}
	return 0
}

func strFromAny(v interface{}) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprintf("%v", v)
}

func splitNonEmpty(s string, sep rune) []string {
	var out []string
	for _, p := range strings.Split(s, string(sep)) {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
