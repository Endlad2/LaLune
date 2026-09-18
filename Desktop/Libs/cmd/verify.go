// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// verify.go — страховка на этапе компиляции: если capi.go случайно
// удалят или переименуют, `go build ./cmd` упадёт с понятной ошибкой
// ещё до того, как dart:ffi будет искать несуществующий символ.
//
// Мы ссылаемся на lalune_init, чтобы компилятор Go гарантировал,
// что символ определён в этом пакете.

package main

import "C"

// verifyExports — пустая функция, которая просто держит ссылку на
// lalune_init, чтобы линкер не выкинул её как неиспользуемую.
//
// (На самом деле //export в capi.go уже этого добивается, но
// эта функция — дополнительная страховка: если capi.go пропадёт,
// компиляция упадёт с "undefined: lalune_init".)
//
//go:noinline
func verifyExports() {
	_ = lalune_init
}
