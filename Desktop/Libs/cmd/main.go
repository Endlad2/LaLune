// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// main.go — точка входа для сборки C-shared библиотеки.
//
// Сборка (из Desktop/Libs/):
//   Linux:   go build -buildmode=c-shared -o build/liblalune.so ./cmd
//   Windows: go build -buildmode=c-shared -o build/lalune.dll ./cmd
//
// Все публичные функции объявлены в ../capi.go через //export.
// main() нужен для buildmode=c-shared, но не вызывается.

package main

func main() {
	// Ничего не делаем — библиотека работает через C-ABI.
	// Все функции находятся в пакете libs (родительская папка),
	// который компилируется в эту же .dll целиком.
}