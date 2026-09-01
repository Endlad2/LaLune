package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Config - конфигурация подключения
type Config struct {
	Peer     string `json:"peer"`
	Password string `json:"password"`
	VkHashes string `json:"vkHashes"`
	Tun      string `json:"tun"`
	Workers  int    `json:"workers"`
}

// App - основное приложение
type App struct {
	config     Config
	clientPID  int
	connected  bool
	clientCmd  *exec.Cmd
	mu         sync.Mutex
	logs       []string
	logFile    string
	configFile string
}

var (
	app           *App
	lastLogOffset int64
)

func main() {
	log.Println("=== LaLune OpenWRT ===")

	app = &App{
		logs:       []string{},
		logFile:    "/opt/etc/csqtt/csqtt-client.log",
		configFile: "/opt/etc/csqtt/csqtt.conf",
	}

	app.loadConfig()
	go app.watchdog()
	go app.startAPI()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	<-sigChan

	log.Println("Завершение...")
	app.Disconnect()
	os.Exit(0)
}

func (a *App) loadConfig() {
	data, err := os.ReadFile(a.configFile)
	if err != nil {
		log.Printf("[CONFIG] Файл не найден: %v", err)
		return
	}

	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.Trim(strings.TrimSpace(parts[1]), "'\"")

		switch key {
		case "PEER":
			a.config.Peer = value
		case "PASSWORD":
			a.config.Password = value
		case "VK":
			a.config.VkHashes = value
		case "TUN":
			a.config.Tun = value
		case "N":
			fmt.Sscanf(value, "%d", &a.config.Workers)
		}
	}

	log.Printf("[CONFIG] Peer: %s, Tun: %s, Workers: %d", a.config.Peer, a.config.Tun, a.config.Workers)
}

func (a *App) saveConfig() {
	content := fmt.Sprintf("PEER='%s'\nPASSWORD='%s'\nVK='%s'\nTUN='%s'\nN='%d'\n",
		a.config.Peer, a.config.Password, a.config.VkHashes, a.config.Tun, a.config.Workers)

	os.MkdirAll(filepath.Dir(a.configFile), 0755)
	os.WriteFile(a.configFile, []byte(content), 0600)
}

// Connect - подключение к VPN
func (a *App) Connect() bool {
	a.mu.Lock()
	defer a.mu.Unlock()

	if a.connected {
		a.addLog("[INFO] Уже подключено")
		return false
	}

	if a.config.Peer == "" || a.config.Password == "" || a.config.VkHashes == "" {
		a.addLog("[ERROR] Конфигурация неполная")
		return false
	}

	a.addLog(fmt.Sprintf("[INFO] Подключаюсь к %s...", a.config.Peer))

	os.Remove(a.logFile)
	lastLogOffset = 0

	corePath := "/opt/etc/csqtt/csqtt-client"
	cmdArgs := []string{
		"--peer", a.config.Peer,
		"--password", a.config.Password,
		"--vk", a.config.VkHashes,
		"--tun", a.config.Tun,
		"-n", fmt.Sprintf("%d", a.config.Workers),
	}

	a.addLog(fmt.Sprintf("[INFO] Команда: %s %s", corePath, strings.Join(cmdArgs, " ")))

	cmd := exec.Command(corePath, cmdArgs...)

	logFileHandle, err := os.OpenFile(a.logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err == nil {
		cmd.Stdout = logFileHandle
		cmd.Stderr = logFileHandle
		defer logFileHandle.Close()
	}

	if err := cmd.Start(); err != nil {
		a.addLog(fmt.Sprintf("[ERROR] Не удалось запустить: %v", err))
		return false
	}

	a.clientCmd = cmd
	a.clientPID = cmd.Process.Pid
	a.connected = true
	a.addLog(fmt.Sprintf("[INFO] Клиент запущен (PID: %d)", a.clientPID))

	go func() {
		cmd.Wait()
		a.mu.Lock()
		a.connected = false
		a.clientPID = 0
		a.clientCmd = nil
		a.mu.Unlock()
		a.addLog("=== Процесс завершён ===")
	}()

	go a.waitForTrafficAndSetupTun()

	return true
}

// Disconnect - отключение
func (a *App) Disconnect() bool {
	a.mu.Lock()
	cmd := a.clientCmd
	pid := a.clientPID
	a.connected = false
	a.clientCmd = nil
	a.clientPID = 0
	a.mu.Unlock()

	if cmd != nil && cmd.Process != nil {
		a.addLog(fmt.Sprintf("[INFO] Останавливаем клиент (PID: %d)...", pid))
		cmd.Process.Kill()
		time.Sleep(1 * time.Second)
	}

	a.cleanupTun()
	a.addLog("[INFO] Отключено")
	return true
}

// waitForTrafficAndSetupTun - ждёт трафик и настраивает TUN
func (a *App) waitForTrafficAndSetupTun() {
	tunconfRegex := regexp.MustCompile(`Tunnel IP:\s*([\d.]+)`)
	dnsRegex := regexp.MustCompile(`DNS:\s*([\d.,]+)`)
	statRegex := regexp.MustCompile(`Активных:\s*(\d+)`)

	var tunIP, tunDNS string
	hasConf := false
	hasTraffic := false

	timeout := time.After(90 * time.Second)

	for !hasConf || !hasTraffic {
		select {
		case <-timeout:
			a.addLog("[TUN] Таймаут ожидания")
			return
		default:
			if content, err := os.ReadFile(a.logFile); err == nil {
				if int64(len(content)) > lastLogOffset {
					newContent := string(content[lastLogOffset:])
					lastLogOffset = int64(len(content))

					lines := strings.Split(newContent, "\n")
					for _, line := range lines {
						line = strings.TrimSpace(line)
						if line == "" {
							continue
						}

						if matches := tunconfRegex.FindStringSubmatch(line); matches != nil {
							tunIP = matches[1]
						}

						if matches := dnsRegex.FindStringSubmatch(line); matches != nil {
							tunDNS = matches[1]
						}

						if tunIP != "" && tunDNS != "" && !hasConf {
							hasConf = true
							a.addLog(fmt.Sprintf("[TUN] TUNCONF: IP=%s DNS=%s", tunIP, tunDNS))
						}

						if matches := statRegex.FindStringSubmatch(line); matches != nil {
							var active int
							fmt.Sscanf(matches[1], "%d", &active)
							if active > 0 {
								hasTraffic = true
								a.addLog("[TUN] Трафик обнаружен")
							}
						}
					}
				}
			}
			time.Sleep(500 * time.Millisecond)
		}
	}

	a.setupTun(tunIP, tunDNS)
}

// setupTun - создание TUN интерфейса
func (a *App) setupTun(tunIP, tunDNS string) {
	a.addLog("[TUN] Настройка TUN...")

	tunName := a.config.Tun
	if tunName == "" {
		tunName = "csqtt0"
	}

	exec.Command("ip", "tuntap", "add", "dev", tunName, "mode", "tun").Run()
	exec.Command("ip", "addr", "add", tunIP+"/32", "dev", tunName).Run()
	exec.Command("ip", "link", "set", tunName, "up").Run()
	exec.Command("ip", "link", "set", tunName, "mtu", "1300").Run()

	dnsServers := strings.Split(tunDNS, ",")
	for _, dns := range dnsServers {
		dns = strings.TrimSpace(dns)
		if dns != "" {
			exec.Command("sh", "-c", fmt.Sprintf("echo 'nameserver %s' >> /etc/resolv.conf", dns)).Run()
		}
	}

	exec.Command("ip", "route", "add", "default", "dev", tunName).Run()

	a.addLog("[TUN] TUN настроен успешно")
}

// cleanupTun - удаление TUN
func (a *App) cleanupTun() {
	a.addLog("[TUN] Удаление TUN...")

	tunName := a.config.Tun
	if tunName == "" {
		tunName = "csqtt0"
	}

	exec.Command("ip", "route", "del", "default", "dev", tunName).Run()
	exec.Command("ip", "tuntap", "del", "dev", tunName, "mode", "tun").Run()

	a.addLog("[TUN] TUN удалён")
}

// watchdog - проверка состояния
func (a *App) watchdog() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		a.mu.Lock()
		connected := a.connected
		pid := a.clientPID
		a.mu.Unlock()

		if !connected {
			continue
		}

		if pid > 0 {
			process, err := os.FindProcess(pid)
			if err != nil || process.Signal(syscall.Signal(0)) != nil {
				a.addLog("[WATCHDOG] Процесс умер, перезапуск...")
				a.Disconnect()
				time.Sleep(2 * time.Second)
				a.Connect()
				continue
			}
		}

		tunName := a.config.Tun
		if tunName == "" {
			tunName = "csqtt0"
		}

		if out, err := exec.Command("ip", "link", "show", tunName).Output(); err != nil || !strings.Contains(string(out), "UP") {
			a.addLog("[WATCHDOG] TUN не поднят, перезапуск...")
			a.Disconnect()
			time.Sleep(2 * time.Second)
			a.Connect()
		}
	}
}

// startAPI - HTTP API
func (a *App) startAPI() {
	http.HandleFunc("/api/status", func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		status := map[string]interface{}{
			"connected": a.connected,
			"pid":       a.clientPID,
		}
		a.mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(status)
	})

	http.HandleFunc("/api/connect", func(w http.ResponseWriter, r *http.Request) {
		result := a.Connect()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]bool{"success": result})
	})

	http.HandleFunc("/api/disconnect", func(w http.ResponseWriter, r *http.Request) {
		result := a.Disconnect()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]bool{"success": result})
	})

	http.HandleFunc("/api/logs", func(w http.ResponseWriter, r *http.Request) {
		content, _ := os.ReadFile(a.logFile)
		w.Header().Set("Content-Type", "text/plain")
		w.Write(content)
	})

	http.HandleFunc("/api/config", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(a.config)
	})

	http.HandleFunc("/api/config/update", func(w http.ResponseWriter, r *http.Request) {
		var newConfig Config
		if err := json.NewDecoder(r.Body).Decode(&newConfig); err != nil {
			json.NewEncoder(w).Encode(map[string]bool{"success": false})
			return
		}

		a.mu.Lock()
		a.config = newConfig
		a.mu.Unlock()

		a.saveConfig()
		json.NewEncoder(w).Encode(map[string]bool{"success": true})
	})

	log.Println("[API] Запущен на :8080")
	http.ListenAndServe(":8080", nil)
}

// addLog - добавление в лог
func (a *App) addLog(message string) {
	log.Println(message)
	a.mu.Lock()
	a.logs = append(a.logs, message)
	if len(a.logs) > 500 {
		a.logs = a.logs[1:]
	}
	a.mu.Unlock()
}

// GetLogs - возвращает логи
func (a *App) GetLogs() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]string{}, a.logs...)
}
