// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// context_nil.go — поддержка Startup(nil) для C-API: Wails передавал
// context.Context, но в c-shared режиме контекст нам не нужен.
// AppCore.ctx остаётся nil, и все места, где он используется,
// должны корректно проверять nil.

package libs

import "context"

// ensureCtx возвращает ctx, если он не nil, иначе context.Background().
// Используется в методах, которые ждут ctx.Done().
func ensureCtx(ctx context.Context) context.Context {
	if ctx == nil {
		return context.Background()
	}
	return ctx
}
