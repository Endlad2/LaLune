// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

package libs

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
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

// Bridge — мост между JS и Go.
type Bridge struct {
	Core          *AppCore
	Tun           TunInterface
	Runner        CoreRunner
	UdpConn       net.Conn
	TunRunning    bool
	TunSetupDone  bool
	CoreProcess   *exec.Cmd
	activeCallIds []string
}

func NewBridge(core *AppCore, tun TunInterface, runner CoreRunner) *Bridge {
	return &Bridge{Core: core, Tun: tun, Runner: runner}
}

func (b *Bridge) Connect(configId int64) bool {
	config := b.Core.GetConfigByID(configId)
	if config == nil {
		b.Core.AddLog("[ERROR] Конфиг не найден")
		return false
	}

	b.Core.SetSelectedConfig(config)

	settings := b.Core.GetSettings()

	if settings.AuthMode == "autoApi" {
		b.Core.AddLog("[АВТО API] Создаю звонки через VK API...")
		hashes, callIds, err := b.Core.RunVkAutoApiCalls(func(s string) {
			b.Core.AddLog(s)
		})
		if err != nil {
			b.Core.AddLog(fmt.Sprintf("[АВТО API] Ошибка: %v", err))
			return false
		}
		config.Hashes = strings.Join(hashes, ",")
		b.activeCallIds = callIds
		b.Core.AddLog(fmt.Sprintf("[АВТО API] Создано звонков: %d", len(callIds)))
	}

	b.Core.AddLog(fmt.Sprintf("[INFO] Подключаюсь к: %s", config.Name))
	b.Core.AddLog(fmt.Sprintf("[INFO] Peer: %s", config.Peer))
	b.Core.AddLog(fmt.Sprintf("[INFO] Режим авторизации: %s", settings.AuthMode))

	go b.connectWorker(*config, settings)
	return true
}

func (b *Bridge) Disconnect() bool {
	b.Core.SetConnected(false)
	b.StopTunnel()

	if b.CoreProcess != nil && b.CoreProcess.Process != nil {
		b.CoreProcess.Process.Kill()
		b.CoreProcess = nil
	}

	if len(b.activeCallIds) > 0 {
		b.Core.AddLog(fmt.Sprintf("[АВТО API] Завершаю %d звонков...", len(b.activeCallIds)))
		b.Core.FinishVkCalls(b.activeCallIds)
		b.activeCallIds = nil
	}

	b.Core.AddLog("Отключено")
	return true
}

func (b *Bridge) connectWorker(config Config, settings Settings) {
	if _, err := os.Stat(b.Core.GetCorePath()); os.IsNotExist(err) {
		b.Core.AddLog("[API] Ядро не найдено, скачиваю...")
		b.Core.NotifyCoreDownloading(true)
		defer b.Core.NotifyCoreDownloading(false)

		remoteVersion := b.Core.FetchLatestVersion()
		if remoteVersion == "" {
			b.Core.AddLog("[ERROR] Не удалось получить версию")
			return
		}
		b.Core.PerformUpdate(remoteVersion)

		if _, err := os.Stat(b.Core.GetCorePath()); os.IsNotExist(err) {
			b.Core.AddLog("[ERROR] Не удалось скачать ядро")
			return
		}

		b.Core.AddLog("[API] Ядро скачано, запускаю через ~10 сек...")
		select {
		case <-b.Core.ctx.Done():
			return
		case <-timeAfterSeconds(10):
		}
	}

	b.Core.AddLog(fmt.Sprintf("=== Подключение к %s ===", config.Name))

	listenPort := GetFreePort()
	cmdArgs := b.BuildCommandForProtocol(&config, settings, listenPort)
	b.Core.AddLog(fmt.Sprintf("Команда: %s", strings.Join(cmdArgs, " ")))

	b.Core.SetConnected(true)

	if b.Runner != nil {
		b.Runner.StartCore(cmdArgs, listenPort, b)
	} else {
		b.Core.AddLog("[ERROR] CoreRunner не инициализирован")
		b.Core.SetConnected(false)
	}
}

// buildCommand — CLI-флаги ядра CSQTT.
//
// Режимы:
//
//	manual  → --vk <hashes> --vk-hash-mode manual --vk-auth-mode vkcalls
//	autoApi → --vk <hashes из calls.start> --vk-hash-mode manual
//	autoVk  → БЕЗ --vk; --vk-hash-mode auto_js --vk-auth-mode auto_js
//	          + --token "<Token из token.json>"
//
// -n = settings.Workers напрямую (без умножения на количество хешей).
func (b *Bridge) buildCommand(config *Config, settings Settings, listenPort int) []string {
	normalizedHashes := strings.ReplaceAll(config.Hashes, " ", ",")
	normalizedHashes = strings.ReplaceAll(normalizedHashes, "\t", ",")
	normalizedHashes = strings.ReplaceAll(normalizedHashes, "\n", ",")
	normalizedHashes = strings.ReplaceAll(normalizedHashes, "\r", ",")

	var cleanHashes []string
	for _, h := range strings.Split(normalizedHashes, ",") {
		if h = strings.TrimSpace(h); h != "" {
			cleanHashes = append(cleanHashes, h)
		}
	}
	hashesCount := len(cleanHashes)
	if hashesCount > 6 {
		hashesCount = 6
		cleanHashes = cleanHashes[:6]
	}
	if hashesCount < 1 {
		hashesCount = 1
		cleanHashes = []string{""}
	}
	hashesJoined := strings.Join(cleanHashes, ",")

	hashMode := "manual"
	authMode := settings.VkAuthMode
	if authMode == "" {
		authMode = "vkcalls"
	}

	isAutoVk := settings.AuthMode == "autoVk"
	isAutoApi := settings.AuthMode == "autoApi"

	if isAutoVk {
		hashMode = "auto_js"
		authMode = "auto_js"
	} else if isAutoApi {
		hashMode = "manual"
	}

	// -n = Workers напрямую.
	workers := settings.Workers
	if workers < MinWorkers {
		workers = DefaultWorkers
	}
	if workers > MaxWorkers {
		workers = MaxWorkers
	}

	captchaMode := settings.CaptchaMode
	if captchaMode == "" {
		captchaMode = "auto"
	}
	turnTransport := settings.TurnTransport
	if turnTransport == "" {
		turnTransport = "udp"
	}

	cmd := []string{
		b.Core.GetCorePath(),

		"--peer", config.Peer,
		"--password", config.Password,

		"--vk-hash-mode", hashMode,
		"--vk-auth-mode", authMode,
		"--listen", fmt.Sprintf("127.0.0.1:%d", listenPort),
		"-n", fmt.Sprintf("%d", workers),

		"--obfs", settings.Obfs,
		"--fingerprint", settings.Fingerprint,
		"--client-ids", settings.ClientIds,
		"--captcha-mode", captchaMode,
		"--turn-transport", turnTransport,

		"--device-id", settings.DeviceId,
	}

	if !isAutoVk {
		cmd = append(cmd, "--vk", hashesJoined)
	}

	if isAutoVk {
		token := b.Core.ReadTokenFromFile()
		if token == "" {
			b.Core.AddLog("[АВТО ВК] ПРЕДУПРЕЖДЕНИЕ: token.json не найден или пуст — ядро упадёт")
		} else {
			cmd = append(cmd, "--token", token)
			b.Core.AddLog("[АВТО ВК] Токен передан из token.json")
		}
	}

	if settings.TurnHost != "" {
		cmd = append(cmd, "--turn", settings.TurnHost)
	}
	if settings.TurnPort != "" {
		cmd = append(cmd, "--port", settings.TurnPort)
	}
	if settings.AllowHashRedistribution {
		cmd = append(cmd, "--allow-hash-redistribution")
	}
	if settings.ValidateVkHashes {
		cmd = append(cmd, "--validate-vk-hashes")
	}

	return cmd
}

func (b *Bridge) ParseTunconf(line string) (string, string) {
	if strings.HasPrefix(line, "TUNCONF:") {
		tunconf := strings.TrimPrefix(line, "TUNCONF:")
		parts := strings.Split(tunconf, ":")
		if len(parts) >= 2 {
			return parts[0], parts[1]
		}
	}
	if strings.Contains(line, "Tunnel IP:") && strings.Contains(line, "DNS:") {
		ipIdx := strings.Index(line, "Tunnel IP:")
		dnsIdx := strings.Index(line, "DNS:")
		if ipIdx >= 0 && dnsIdx > ipIdx {
			ipPart := strings.TrimSpace(line[ipIdx+10 : dnsIdx])
			ipPart = strings.TrimSpace(strings.TrimSuffix(ipPart, "|"))
			ipPart = strings.TrimSpace(ipPart)
			if slashIdx := strings.Index(ipPart, "/"); slashIdx >= 0 {
				ipPart = ipPart[:slashIdx]
			}
			dnsPart := strings.TrimSpace(line[dnsIdx+4:])
			if pipeIdx := strings.Index(dnsPart, "|"); pipeIdx >= 0 {
				dnsPart = dnsPart[:pipeIdx]
			}
			dnsPart = strings.TrimSpace(dnsPart)
			if ipPart != "" && dnsPart != "" {
				return ipPart, dnsPart
			}
		}
	}
	return "", ""
}

func (b *Bridge) SetupTun() error {
	if b.TunSetupDone {
		return nil
	}
	if err := b.Tun.Setup(); err != nil {
		return err
	}
	b.TunSetupDone = true
	return nil
}

func (b *Bridge) StartTunnel(corePort int) {
	if b.TunRunning {
		return
	}
	udpConn, err := net.Dial("udp", fmt.Sprintf("127.0.0.1:%d", corePort))
	if err != nil {
		b.Core.AddLog(fmt.Sprintf("[TUN] UDP ошибка: %v", err))
		return
	}
	b.UdpConn = udpConn
	b.TunRunning = true
	b.Tun.Start(udpConn, &b.TunRunning)
	b.Core.AddLog("[TUN] Пакетный мост запущен")
}

func (b *Bridge) StopTunnel() {
	b.TunRunning = false
	if b.UdpConn != nil {
		b.UdpConn.Close()
		b.UdpConn = nil
	}
	b.Tun.Stop()
	b.TunSetupDone = false
}

func (b *Bridge) SetupRoutes(tunIP string, tunDNS string) {
	b.Tun.SetupRoutes(tunIP, tunDNS)
	b.Core.AddLog("[TUN] Маршруты и DNS настроены")
}

func (b *Bridge) CleanupRoutes() {
	b.Tun.CleanupRoutes()
}

// BuildCommandForProtocol выбирает командную строку ядра по протоколу конфига.
// Для CSQTT используется исторический buildCommand; для остальных протоколов
// (FREETURN/OLCRTC/OPENFLUX/TOTS) формируется общий набор аргументов, а само
// ядро берётся по имени протокола (GetCorePathForProtocol).
func (b *Bridge) BuildCommandForProtocol(config *Config, settings Settings, listenPort int) []string {
	proto := NormalizeProtocol(config.Protocol)
	if proto == "CSQTT" {
		return b.buildCommand(config, settings, listenPort)
	}

	b.Core.AddLog(fmt.Sprintf("[PROTO] Запуск конфига с протоколом %s", proto))

	cmd := []string{
		b.Core.GetCorePathForProtocol(proto),
		"--protocol", proto,
		"--peer", config.Peer,
		"--password", config.Password,
		"--listen", fmt.Sprintf("127.0.0.1:%d", listenPort),
		"--device-id", settings.DeviceId,
	}
	if config.Hashes != "" {
		cmd = append(cmd, "--hashes", strings.ReplaceAll(config.Hashes, " ", ","))
	}
	return cmd
}
