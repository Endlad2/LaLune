package libs

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
)

// TunInterface - интерфейс для платформозависимого TUN
type TunInterface interface {
	Setup() error
	Start(udpConn net.Conn, running *bool)
	Stop()
	SetupRoutes(tunIP string, tunDNS string)
	CleanupRoutes()
}

// CoreRunner - интерфейс для платформозависимого запуска ядра
type CoreRunner interface {
	StartCore(cmdArgs []string, listenPort int, bridge *Bridge)
}

// Bridge - мост между JS и Go, содержит общую логику подключения
type Bridge struct {
	Core         *AppCore
	Tun          TunInterface
	Runner       CoreRunner
	UdpConn      net.Conn
	TunRunning   bool
	TunSetupDone bool
	CoreProcess  *exec.Cmd
}

func NewBridge(core *AppCore, tun TunInterface, runner CoreRunner) *Bridge {
	return &Bridge{
		Core:   core,
		Tun:    tun,
		Runner: runner,
	}
}

func (b *Bridge) Connect(configId int64) bool {
	config := b.Core.GetConfigByID(configId)
	if config == nil {
		b.Core.AddLog("[ERROR] Конфиг не найден")
		return false
	}

	b.Core.AddLog(fmt.Sprintf("[INFO] Подключаюсь к: %s", config.Name))
	b.Core.AddLog(fmt.Sprintf("[INFO] Peer: %s", config.Peer))

	go b.connectWorker(*config)
	return true
}

func (b *Bridge) Disconnect() bool {
	b.Core.SetConnected(false)
	b.StopTunnel()

	if b.CoreProcess != nil && b.CoreProcess.Process != nil {
		b.CoreProcess.Process.Kill()
		b.CoreProcess = nil
	}

	b.Core.AddLog("Отключено")
	return true
}

func (b *Bridge) connectWorker(config Config) {
	// Проверяем наличие ядра
	if _, err := os.Stat(b.Core.GetCorePath()); os.IsNotExist(err) {
		b.Core.AddLog("[API] Ядро не найдено, скачиваю...")
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
	}

	b.Core.AddLog(fmt.Sprintf("=== Подключение к %s ===", config.Name))

	listenPort := GetFreePort()
	cmdArgs := b.buildCommand(&config, listenPort)
	b.Core.AddLog(fmt.Sprintf("Команда: %s", strings.Join(cmdArgs, " ")))

	b.Core.SetConnected(true)

	// Запуск ядра (платформозависимый)
	if b.Runner != nil {
		b.Runner.StartCore(cmdArgs, listenPort, b)
	} else {
		b.Core.AddLog("[ERROR] CoreRunner не инициализирован")
		b.Core.SetConnected(false)
	}
}

func (b *Bridge) buildCommand(config *Config, listenPort int) []string {
	// Нормализуем разделители хешей: пробелы, табы, новые строки -> запятые
	normalizedHashes := strings.ReplaceAll(config.Hashes, " ", ",")
	normalizedHashes = strings.ReplaceAll(normalizedHashes, "\t", ",")
	normalizedHashes = strings.ReplaceAll(normalizedHashes, "\n", ",")
	normalizedHashes = strings.ReplaceAll(normalizedHashes, "\r", ",")
	
	// Убираем пустые элементы
	hashesList := strings.Split(normalizedHashes, ",")
	var cleanHashes []string
	for _, h := range hashesList {
		h = strings.TrimSpace(h)
		if h != "" {
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
	
	// Объединяем хеши через запятую для флага -vk
	hashesJoined := strings.Join(cleanHashes, ",")

	settings := b.Core.GetSettings()
	workersPerHash := settings.WorkersPerHash
	if workersPerHash < 9 {
		workersPerHash = 9
	}
	totalWorkers := workersPerHash * hashesCount

	cmd := []string{
		b.Core.GetCorePath(),
		"-peer", config.Peer,
		"-n", fmt.Sprintf("%d", totalWorkers),
		"-listen", fmt.Sprintf("127.0.0.1:%d", listenPort),
		"-vk", hashesJoined,
		"-fingerprint", settings.Fingerprint,
		"-client-ids", settings.ClientIds,
		"-obfs", settings.Obfs,
		"-vk-auth-mode", settings.VkAuthMode,
		"-device-id", settings.DeviceId,
		"-password", config.Password,
		"-captcha-mode", settings.CaptchaMode,
	}

	if settings.TurnHost != "" {
		cmd = append(cmd, "-turn", settings.TurnHost)
	}
	if settings.TurnPort != "" {
		cmd = append(cmd, "-port", settings.TurnPort)
	}

	return cmd
}

// Экспортируемые методы для использования из платформозависимого кода
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
