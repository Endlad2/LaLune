// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// bridge_export.go — методы AppCore для C-ABI:
//   - ConnectViaBridge / DisconnectViaBridge — потому что Connect/Disconnect
//     живут в Bridge (который создаётся платформенно-зависимо).
//   - UpdateCoreAndWaitSync — синхронная версия UpdateCoreAndWait.
//   - RegenerateDeviceId — генерация нового UUID.
//   - GetSmartTunnel / SetSmartTunnel — доступ к SmartTunnel для lalune_shutdown.
//
// Bridge создаётся один раз при Startup платформенно-зависимым кодом и
// регистрируется через SetBridge().

package libs

import (
	"sync"

	"github.com/google/uuid"
)

var (
	globalBridge *Bridge
	bridgeMu     sync.RWMutex
)

// SetBridge — регистрирует Bridge для использования в C-ABI.
func (a *AppCore) SetBridge(b *Bridge) {
	bridgeMu.Lock()
	defer bridgeMu.Unlock()
	globalBridge = b
}

// getBridge — возвращает активный Bridge или nil.
func getBridge() *Bridge {
	bridgeMu.RLock()
	defer bridgeMu.RUnlock()
	return globalBridge
}

// ConnectViaBridge — вызывает Bridge.Connect (для C-ABI).
func (a *AppCore) ConnectViaBridge(id int64) bool {
	b := getBridge()
	if b == nil {
		a.AddLog("[CAPI] Bridge не инициализирован — Connect невозможен")
		return false
	}
	return b.Connect(id)
}

// DisconnectViaBridge — вызывает Bridge.Disconnect (для C-ABI).
func (a *AppCore) DisconnectViaBridge() bool {
	b := getBridge()
	if b == nil {
		a.AddLog("[CAPI] Bridge не инициализирован — Disconnect невозможен")
		return false
	}
	return b.Disconnect()
}

// UpdateCoreAndWaitSync — синхронная версия обновления ядра.
// Возвращает true, если ядро успешно скачано.
func (a *AppCore) UpdateCoreAndWaitSync() bool {
	if a.IsConnected() {
		b := getBridge()
		if b != nil {
			b.Disconnect()
		}
		waitMs(1000)
	}
	remote := a.FetchLatestVersion()
	if remote == "" {
		return false
	}
	a.PerformUpdate(remote)
	// Проверяем, что файл на месте.
	if _, err := statFile(a.GetCorePath()); err != nil {
		return false
	}
	return true
}

// RegenerateDeviceId — генерирует новый UUID, сохраняет в settings, возвращает.
func (a *AppCore) RegenerateDeviceId() string {
	newId := uuid.New().String()

	a.mu.Lock()
	a.settings.DeviceId = newId
	data, _ := jsonMarshalIndent(a.settings)
	_ = writeFile(a.settingsFile, data, 0644)
	a.mu.Unlock()

	a.AddLog("[SETTINGS] Device ID перегенерирован")
	return newId
}

// GetSmartTunnel — доступ к SmartTunnel (для lalune_shutdown).
func (a *AppCore) GetSmartTunnel() *SmartTunnel {
	return a.smartTunnel
}

// SetSmartTunnel — устанавливает SmartTunnel (вызывается из Startup).
func (a *AppCore) SetSmartTunnel(st *SmartTunnel) {
	a.smartTunnel = st
}
