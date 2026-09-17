// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// tokenfile.go — вспомогательные методы для работы с token.json.
// Основной метод чтения — AppCore.ReadTokenFromFile() (см. vk_api.go).
//
// Путь:
//   Windows: %APPDATA%\.la-lune\token.json
//   Linux:   ~/.la-lune/token.json
//
// Формат:
//   {
//     "Token": "vk1.a.xxxxx",
//     "SavedAt": "2026-09-17T12:34:56.789Z"
//   }

package libs

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// TokenFilePath — полный путь к token.json в папке приложения.
func (a *AppCore) TokenFilePath() string {
	return filepath.Join(a.appDir, "token.json")
}

// TokenFileExists — есть ли файл token.json.
func (a *AppCore) TokenFileExists() bool {
	_, err := os.Stat(a.TokenFilePath())
	return err == nil
}

// ReadTokenFromFileStrict — строгий парсер: возвращает ошибку, если файла
// нет или токен пустой. Используется в местах, где нужна диагностика.
func (a *AppCore) ReadTokenFromFileStrict() (string, error) {
	data, err := os.ReadFile(a.TokenFilePath())
	if err != nil {
		return "", err
	}

	var j struct {
		Token string `json:"Token"`
	}
	if err := json.Unmarshal(data, &j); err != nil {
		return "", err
	}

	token := strings.TrimSpace(j.Token)
	if token == "" {
		return "", os.ErrNotExist
	}
	return token, nil
}
