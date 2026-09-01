//go:build linux
// +build linux

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Импортируем Libs
import "lalune-desktop/Libs"

// App - основное приложение для Linux
type App struct {
	core      *libs.AppCore
	bridge    *libs.Bridge
	tun       *LinuxTun
	runner    *LinuxRunner
	isRoot    bool
	clientPID int
	sudoPass  string
	mu        sync.Mutex
}

type LinuxTun struct {
	app          *App
	bypassRoutes []string
	mu           sync.Mutex
}

func (t *LinuxTun) Setup() error {
	return nil
}

func (t *LinuxTun) Start(udpConn interface{ Call() }, running *bool) {
}

func (t *LinuxTun) Stop() {
}

func (t *LinuxTun) SetupRoutes(tunIP string, tunDNS string) {
	t.mu.Lock()
	defer t.mu.Unlock()

	t.app.core.AddLog(fmt.Sprintf("[TUN] Настройка TUN (IP: %s, DNS: %s)...", tunIP, tunDNS))

	cmd := fmt.Sprintf("ip tuntap add dev csqtt0 mode tun && ip addr add %s/32 dev csqtt0 && ip link set csqtt0 up && ip link set csqtt0 mtu 1300", tunIP)
	t.app.runSudo(cmd)

	dnsServers := strings.Split(tunDNS, ",")
	for _, dns := range dnsServers {
		dns = strings.TrimSpace(dns)
		if dns != "" {
			t.app.runSudo(fmt.Sprintf("echo 'nameserver %s' >> /etc/resolv.conf", dns))
		}
	}

	t.app.runSudo("ip route add default dev csqtt0")

	t.app.core.AddLog("[TUN] TUN настроен успешно")
}

func (t *LinuxTun) CleanupRoutes() {
	t.mu.Lock()
	defer t.mu.Unlock()

	t.app.core.AddLog("[TUN] Удаление TUN...")

	t.app.runSudo("ip route del default dev csqtt0 2>/dev/null || true")
	t.app.runSudo("ip tuntap del dev csqtt0 mode tun 2>/dev/null || true")

	t.app.core.AddLog("[TUN] TUN удалён")
}

func (t *LinuxTun) AddBypassRoute(ip string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.bypassRoutes = append(t.bypassRoutes, ip)
}

// LinuxRunner реализует libs.CoreRunner для Linux
type LinuxRunner struct {
	app *App
}

func (r *LinuxRunner) StartCore(cmdArgs []string, listenPort int, bridge *libs.Bridge) {
	r.startCoreWithSudo(cmdArgs, listenPort, bridge)
}

func (r *LinuxRunner) startCoreWithSudo(cmdArgs []string, listenPort int, bridge *libs.Bridge) {
	logFile := filepath.Join(os.TempDir(), "lalune_core_logs.txt")
	os.Remove(logFile)

	cmdStr := strings.Join(cmdArgs, " ")
	fullCmd := fmt.Sprintf("%s > %s 2>&1", cmdStr, logFile)

	bridge.Core.AddLog("[INFO] Запуск ядра через sudo...")

	cmd := exec.Command("sh", "-c", r.app.runSudoCommand(fullCmd))
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		bridge.Core.AddLog(fmt.Sprintf("[ERROR] Не удалось запустить: %v", err))
		bridge.Core.SetConnected(false)
		return
	}

	r.app.mu.Lock()
	r.app.clientPID = cmd.Process.Pid
	r.app.mu.Unlock()

	bridge.Core.AddLog(fmt.Sprintf("[INFO] Ядро запущено (PID: %d)", cmd.Process.Pid))

	tunconfChan := make(chan [2]string, 1)
	trafficChan := make(chan bool, 1)
	lastOffset := int64(0)

	listenRe := regexp.MustCompile(`Слушаю:\s*127\.0\.0\.1:(\d+)`)
	statRe := regexp.MustCompile(`Активных:\s*(\d+)`)
	coreListenPort := 52230

	go func() {
		for bridge.Core.IsConnected() {
			if content, err := os.ReadFile(logFile); err == nil {
				if int64(len(content)) > lastOffset {
					newContent := string(content[lastOffset:])
					lastOffset = int64(len(content))

					lines := strings.Split(newContent, "\n")
					for _, line := range lines {
						line = strings.TrimSpace(line)
						if line == "" {
							continue
						}

						if strings.Contains(line, "__CSQTT_EVENT__|STOPPED|") {
							continue
						}

						bridge.Core.AddLog(line)

						if matches := listenRe.FindStringSubmatch(line); matches != nil {
							fmt.Sscanf(matches[1], "%d", &coreListenPort)
							bridge.Core.AddLog(fmt.Sprintf("[TUN] Порт ядра: %d", coreListenPort))
						}

						tunIP, tunDNS := bridge.ParseTunconf(line)
						if tunIP != "" && tunDNS != "" {
							select {
							case tunconfChan <- [2]string{tunIP, tunDNS}:
							default:
							}
						}

						if matches := statRe.FindStringSubmatch(line); matches != nil {
							var active int
							fmt.Sscanf(matches[1], "%d", &active)
							if active > 0 {
								select {
								case trafficChan <- true:
								default:
								}
							}
						}
					}
				}
			}
			time.Sleep(500 * time.Millisecond)
		}
	}()

	go func() {
		var tunIP, tunDNS string
		hasConf := false
		hasTraffic := false

		for !hasConf || !hasTraffic {
			select {
			case conf := <-tunconfChan:
				tunIP = conf[0]
				tunDNS = conf[1]
				hasConf = true
				bridge.Core.AddLog(fmt.Sprintf("[TUN] TUNCONF получен: IP=%s DNS=%s", tunIP, tunDNS))
			case <-trafficChan:
				hasTraffic = true
				bridge.Core.AddLog("[TUN] Трафик обнаружен (Активных > 0)")
			case <-time.After(90 * time.Second):
				bridge.Core.AddLog("[TUN] Таймаут ожидания")
				bridge.Core.SetConnected(false)
				return
			}
		}

		bridge.Core.AddLog("[TUN] Настройка TUN...")
		time.Sleep(750 * time.Millisecond)

		if tun, ok := bridge.Tun.(*LinuxTun); ok {
			tun.SetupRoutes(tunIP, tunDNS)
		}
	}()

	go func() {
		cmd.Wait()
		bridge.Core.AddLog("=== Процесс завершён ===")
		bridge.Core.SetConnected(false)
		bridge.StopTunnel()
		bridge.CleanupRoutes()
		r.app.mu.Lock()
		r.app.clientPID = 0
		r.app.mu.Unlock()
	}()
}

func NewApp() *App {
	core := libs.NewAppCore()
	tun := &LinuxTun{}
	app := &App{
		core: core,
		tun:  tun,
	}
	tun.app = app
	app.runner = &LinuxRunner{app: app}
	app.bridge = libs.NewBridge(core, tun, app.runner)
	return app
}

func (a *App) startup(ctx context.Context) {
	a.core.Startup(ctx)
	a.core.LoadConfigs()

	a.isRoot = os.Geteuid() == 0

	if a.isRoot {
		a.core.AddLog("[INFO] Запущено от root")
	} else {
		a.core.AddLog("[INFO] Запущено без root прав")
		a.core.AddLog("[INFO] Запросите пароль root в окне")
	}
}

func (a *App) runSudo(command string) error {
	fullCmd := a.runSudoCommand(command)
	cmd := exec.Command("sh", "-c", fullCmd)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func (a *App) runSudoCommand(command string) string {
	a.mu.Lock()
	pass := a.sudoPass
	a.mu.Unlock()

	if pass == "" {
		return fmt.Sprintf("sudo %s", command)
	}

	return fmt.Sprintf("echo '%s' | sudo -S %s", pass, command)
}

func (a *App) SetSudoPassword(password string) bool {
	a.mu.Lock()
	a.sudoPass = password
	a.mu.Unlock()

	cmd := exec.Command("sh", "-c", a.runSudoCommand("echo OK"))
	if err := cmd.Run(); err != nil {
		a.mu.Lock()
		a.sudoPass = ""
		a.mu.Unlock()
		a.core.AddLog("[SUDO] Неверный пароль")
		return false
	}

	a.core.AddLog("[SUDO] Пароль сохранён")
	return true
}

func (a *App) GetConfigsJson() string {
	return a.core.GetConfigsJson()
}

func (a *App) GetSettingsJson() string {
	return a.core.GetSettingsJson()
}

func (a *App) GetLogsJson() string {
	return a.core.GetLogsJson()
}

func (a *App) GetStatusJson() string {
	return fmt.Sprintf(`{"connected":%v}`, a.core.IsConnected())
}

func (a *App) SaveConfig(link string) bool {
	return a.core.SaveConfig(link)
}

func (a *App) DeleteConfig(id int64) bool {
	return a.core.DeleteConfig(id)
}

func (a *App) SaveSettings(settingsJson string) bool {
	return a.core.SaveSettings(settingsJson)
}

func (a *App) CheckUpdate() string {
	version, hasUpdate, err := a.core.CheckUpdateSync()
	if err != nil {
		return fmt.Sprintf(`{"error":"%s"}`, err.Error())
	}
	return fmt.Sprintf(`{"update":%v,"version":"%s"}`, hasUpdate, version)
}

func (a *App) UpdateCoreAndWait() bool {
	if a.core.IsConnected() {
		a.core.AddLog("[UPDATE] Отключаемся перед обновлением...")
		a.bridge.Disconnect()
		time.Sleep(1 * time.Second)
	}

	remoteVersion := a.core.FetchLatestVersion()
	if remoteVersion == "" {
		a.core.AddLog("[UPDATE] Не удалось получить версию")
		return false
	}

	a.core.PerformUpdate(remoteVersion)
	a.core.AddLog("[UPDATE] Обновление завершено")
	return true
}

func (a *App) Connect(configId int64) bool {
	remoteVersion, hasUpdate, err := a.core.CheckUpdateSync()
	if err == nil && hasUpdate {
		a.core.AddLog(fmt.Sprintf("[UPDATE] Доступна версия %s. Обновитесь перед подключением.", remoteVersion))
		return false
	}

	return a.bridge.Connect(configId)
}

func (a *App) Disconnect() bool {
	a.mu.Lock()
	pid := a.clientPID
	a.mu.Unlock()

	if pid > 0 {
		a.core.AddLog(fmt.Sprintf("[INFO] Останавливаем клиент (PID: %d)...", pid))
		syscall.Kill(pid, syscall.SIGTERM)
		time.Sleep(1 * time.Second)
		syscall.Kill(pid, syscall.SIGKILL)
	}

	result := a.bridge.Disconnect()

	a.tun.CleanupRoutes()

	return result
}

func (a *App) ClearLogs() bool {
	return a.core.ClearLogs()
}

func (a *App) UpdateCore() bool {
	return a.core.UpdateCore()
}