// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// main.go — точка входа для сборки C-shared библиотеки.
//
// ВАЖНО: все C-экспорты (//export lalune_*) живут в capi.go —
// в ЭТОЙ ЖЕ директории. Это обязательно, потому что `go build ./cmd`
// компилирует только пакеты из cmd/, а не из родительской Desktop/Libs/.
//
// Сборка (из Desktop/Libs/):
//   Linux:   go build -buildmode=c-shared -o build/liblalune.so ./cmd
//   Windows: go build -buildmode=c-shared -o build/lalune.dll ./cmd
//
// main() нужен для buildmode=c-shared, но не вызывается.

package main

func main() {
	// Ничего не делаем — библиотека работает через C-ABI.
	// Все //export-функции объявлены в capi.go рядом с этим файлом.
}
