// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// platform.go — общий интерфейс для платформо-зависимых TUN/Runner.
// Реализации — в Desktop/Linux/platform_linux.go и Desktop/Windows/platform_windows.go.

package libs

import (
	"fmt"
	"net"
	"os/exec"
)

// TunInterface — интерфейс для платформозависимого TUN.
type TunInterface interface {
	Setup() error
	Start(udpConn net.Conn, running *bool)
	Stop()
	SetupRoutes(tunIP string, tunDNS string)
	CleanupRoutes()
}

// CoreRunner — интерфейс для платформозависимого запуска ядра.
type CoreRunner interface {
	StartCore(cmdArgs []string, listenPort int, bridge *Bridge)
}

// InitPlatform вызывается из платформенного init() при загрузке пакета.
// Он создаёт Bridge с нужными TunInterface и CoreRunner, регистрирует его
// в AppCore для C-API.
type PlatformInit func(core *AppCore) (*Bridge, error)

var platformInit PlatformInit

// RegisterPlatformInit — платформенные файлы вызывают эту функцию в init().
func RegisterPlatformInit(fn PlatformInit) {
	platformInit = fn
}

// BuildBridge — создаёт Bridge с платформенными Tun/Runner.
// Вызывается из lalune_init после Startup.
func BuildBridge(core *AppCore) error {
	if platformInit == nil {
		return fmt.Errorf("platform init не зарегистрирован (собран без платформенного файла?)")
	}
	bridge, err := platformInit(core)
	if err != nil {
		return err
	}
	core.SetBridge(bridge)
	return nil
}

// ============================================================
//  Общие утилиты
// ============================================================

// GetFreePort — свободный TCP-порт для локального listen.
func GetFreePort() int {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 9000
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

// execCommandSilent — запуск внешней команды без вывода.
func execCommandSilent(name string, args ...string) error {
	return exec.Command(name, args...).Run()
}
