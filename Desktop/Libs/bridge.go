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

	// Запоминаем выбранный конфиг глобально — пригодится в SettingsPage.
	b.Core.SetSelectedConfig(config)

	settings := b.Core.GetSettings()

	if settings.AuthMode == "autoApi" {
		b.Core.AddLog("[AUTO API] Создаю звонки через VK API...")
		hashes, callIds, err := b.Core.RunVkAutoApiCalls(func(s string) {
			b.Core.AddLog(s)
		})
		if err != nil {
			b.Core.AddLog(fmt.Sprintf("[AUTO API] Ошибка: %v", err))
			return false
		}
		config.Hashes = strings.Join(hashes, ",")
		b.activeCallIds = callIds
		b.Core.AddLog(fmt.Sprintf("[AUTO API] Создано звонков: %d", len(callIds)))
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
		b.Core.AddLog(fmt.Sprintf("[AUTO API] Завершаю %d звонков...", len(b.activeCallIds)))
		b.Core.FinishVkCalls(b.activeCallIds)
		b.activeCallIds = nil
	}

	b.Core.AddLog("Отключено")
	return true
}

func (b *Bridge) connectWorker(config Config, settings Settings) {
	if _, err := os.Stat(b.Core.GetCorePath()); os.IsNotExist(err) {
		b.Core.AddLog("[API] Ядро не найдено, скачиваю...")
		// Сообщаем UI, что ядро скачивается — тост «Подождите, скачивается ядро...»
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

		// Небольшая пауза, чтобы ядро успело «осесть» и UI показал сообщение
		// ровно те 10 секунд, о которых говорит тост.
		b.Core.AddLog("[API] Ядро скачано, запускаю через ~10 сек...")
		select {
		case <-b.Core.ctx.Done():
			return
		case <-timeAfterSeconds(10):
			// продолжаем
		}
	}

	b.Core.AddLog(fmt.Sprintf("=== Подключение к %s ===", config.Name))

	listenPort := GetFreePort()
	cmdArgs := b.buildCommand(&config, settings, listenPort)
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

	switch settings.AuthMode {
	case "autoVk":
		hashMode = "auto_js"
		authMode = "auto_js"
	case "autoApi":
		hashMode = "manual"
	}

	workersPerHash := settings.WorkersPerHash
	if workersPerHash < 9 {
		workersPerHash = 9
	}
	totalWorkers := workersPerHash * hashesCount

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
		"--vk", hashesJoined,
		"--vk-hash-mode", hashMode,
		"--vk-auth-mode", authMode,
		"--listen", fmt.Sprintf("127.0.0.1:%d", listenPort),
		"-n", fmt.Sprintf("%d", totalWorkers),

		"--obfs", settings.Obfs,
		"--fingerprint", settings.Fingerprint,
		"--client-ids", settings.ClientIds,
		"--captcha-mode", captchaMode,
		"--turn-transport", turnTransport,

		"--device-id", settings.DeviceId,
	}

	// Токен передаём только в режиме auto_js.
	if hashMode == "auto_js" {
		token := b.Core.GetVKToken()
		if token != "" {
			cmd = append(cmd, "--token", token)
		} else {
			b.Core.AddLog("[AUTO ВК] ПРЕДУПРЕЖДЕНИЕ: токен не задан, ядро упадёт")
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
