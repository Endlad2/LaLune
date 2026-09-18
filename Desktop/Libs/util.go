// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// util.go — тонкие обёртки, чтобы не тащить в каждый файл time/os/encoding/json.

package libs

import (
	"encoding/json"
	"os"
	"time"
)

func waitMs(ms int) {
	time.Sleep(time.Duration(ms) * time.Millisecond)
}

func statFile(path string) (os.FileInfo, error) {
	return os.Stat(path)
}

func writeFile(path string, data []byte, perm os.FileMode) error {
	return os.WriteFile(path, data, perm)
}

func jsonMarshalIndent(v any) ([]byte, error) {
	return json.MarshalIndent(v, "", "  ")
}
