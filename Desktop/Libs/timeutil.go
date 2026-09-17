// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

package libs

import "time"

// timeAfterSeconds — обёртка над time.After, чтобы bridge.go не тянул time.
func timeAfterSeconds(sec int) <-chan time.Time {
	return time.After(time.Duration(sec) * time.Second)
}
