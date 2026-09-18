// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// main.go — точка входа для сборки C-shared библиотеки.
//
// Сборка:
//   Linux:   go build -buildmode=c-shared -o build/liblalune.so ./cmd
//   Windows: go build -buildmode=c-shared -o build/lalune.dll ./cmd
//
// Все публичные функции объявлены в ../Libs/capi.go через //export.
// main() здесь нужен для buildmode=c-shared, но не вызывается.

package main

import (
	_ "lalune-desktop/Libs"
)

func main() {
	// Ничего не делаем — библиотека работает через C-ABI.
}
