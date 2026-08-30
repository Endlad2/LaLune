package main

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/google/uuid"
	_ "modernc.org/sqlite"
)

const (
	LATEST_URL        = "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST"
	CORE_URL_TEMPLATE = "https://github.com/Endlad2/csqtt-core/releases/download/%s/%s"
	WINTUN_URL        = "https://www.wintun.net/builds/wintun-0.14.1.zip"
	PROXY_URL         = "http://31.77.148.203:8855/?url="
	USER_AGENT        = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
	MIN_SPEED_MBPS    = 1.0
	HTTP_TIMEOUT      = 15 * time.Second
)

var (
	shell32DLL      = syscall.NewLazyDLL("shell32.dll")
	procShellExecEx = shell32DLL.NewProc("ShellExecuteExW")
)

const (
	SEE_MASK_NOCLOSEPROCESS = 0x00000040
	SW_HIDE                 = 0
)

type shellExecuteInfo struct {
	cbSize       uint32
	fMask        uint32
	hwnd         uintptr
	lpVerb       *uint16
	lpFile       *uint16
	lpParameters *uint16
	lpDirectory  *uint16
	nShow        int32
	hInstApp     uintptr
	lpIDList     uintptr
	lpClass      *uint16
	hkeyClass    uintptr
	dwHotKey     uint32
	hIcon        uintptr
	hProcess     uintptr
}

type Config struct {
	ID       int64  `json:"id"`
	Protocol string `json:"protocol"`
	Peer     string `json:"peer"`
	Password string `json:"password"`
	Hashes   string `json:"hashes"`
	Name     string `json:"name"`
}

type Settings struct {
	Peer           string `json:"peer"`
	VkHashes       string `json:"vkHashes"`
	TurnHost       string `json:"turnHost"`
	TurnPort       string `json:"turnPort"`
	WorkersPerHash int    `json:"workersPerHash"`
	Obfs           string `json:"obfs"`
	Fingerprint    string `json:"fingerprint"`
	ClientIds      string `json:"clientIds"`
	VkAuthMode     string `json:"vkAuthMode"`
	CaptchaMode    string `json:"captchaMode"`
	DeviceId       string `json:"deviceId"`
	AutoConnect    bool   `json:"autoConnect"`
}

// TUN интерфейс (абстракция)
type TunInterface interface {
	Setup() error
	Start(udpConn net.Conn, running *bool)
	Stop()
	SetupRoutes(tunIP string, tunDNS string)
	CleanupRoutes()
	AddLog(message string)
}

type App struct {
	ctx             context.Context
	db              *sql.DB
	settings        Settings
	settingsFile    string
	latestFile      string
	corePath        string
	wintunPath      string
	appDir          string
	isConnected     bool
	coreProcess     *exec.Cmd
	mu              sync.Mutex
	logs            []string
	logCallback     func(string)
	statusCallback  func(bool)
	configsCallback func(string)
	updateCallback  func(string)
	isDownloading   bool

	// TUN интерфейс
	tun            TunInterface
	udpConn        net.Conn
	tunRunning     bool
	tunSetupDone   bool
}

// Функция для создания TUN интерфейса (будет переопределена в платформозависимых файлах)
var newTun func(app *App) TunInterface

func NewApp() *App {
	return &App{
		logs: []string{},
	}
}

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	a.appDir = a.getAppDataDir()
	a.settingsFile = filepath.Join(a.appDir, "settings.json")
	a.latestFile = filepath.Join(a.appDir, "LATEST")
	a.corePath = filepath.Join(a.appDir, a.getCoreFilename())
	a.wintunPath = filepath.Join(a.appDir, "wintun.dll")

	os.MkdirAll(a.appDir, 0755)

	a.initDB()
	a.loadSettings()
	
	// Создаем TUN интерфейс через глобальную функцию
	if newTun != nil {
		a.tun = newTun(a)
	} else {
		a.addLog("[ERROR] TUN не инициализирован для этой платформы")
	}

	go a.checkUpdateBackground()
}

func (a *App) getAppDataDir() string {
	if runtime.GOOS == "windows" {
		appdata := os.Getenv("APPDATA")
		if appdata == "" {
			home, _ := os.UserHomeDir()
			appdata = filepath.Join(home, "AppData", "Roaming")
		}
		return filepath.Join(appdata, ".la-lune")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".la-lune")
}

func (a *App) getCoreFilename() string {
	switch runtime.GOOS {
	case "windows":
		return "client-windows-x86_64.exe"
	case "darwin":
		return "client-macos-x86_64"
	default:
		return "client-linux-x86_64"
	}
}

func (a *App) initDB() {
	dbPath := filepath.Join(a.appDir, "configs.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		fmt.Printf("[DB] Ошибка: %v\n", err)
		return
	}

	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS configs (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		protocol TEXT NOT NULL DEFAULT 'CSQTT',
		peer TEXT NOT NULL DEFAULT '',
		password TEXT NOT NULL DEFAULT '',
		hashes TEXT NOT NULL DEFAULT '',
		name TEXT DEFAULT '',
		created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
		updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
	)`)
	if err != nil {
		fmt.Printf("[DB] Ошибка создания таблицы: %v\n", err)
	}

	a.db = db
}

func (a *App) loadSettings() {
	data, err := os.ReadFile(a.settingsFile)
	if err != nil {
		a.settings = Settings{
			WorkersPerHash: 9,
			Obfs:           "video",
			Fingerprint:    "firefox",
			ClientIds:      "8202606,6287487",
			VkAuthMode:     "vkcalls",
			CaptchaMode:    "auto",
			DeviceId:       uuid.New().String(),
		}
		a.saveSettingsFile()
		return
	}

	json.Unmarshal(data, &a.settings)

	if a.settings.DeviceId == "" {
		a.settings.DeviceId = uuid.New().String()
		a.saveSettingsFile()
	}
}

func (a *App) saveSettingsFile() {
	data, _ := json.MarshalIndent(a.settings, "", "  ")
	os.WriteFile(a.settingsFile, data, 0644)
}

func (a *App) loadConfigs() {
	if a.db == nil {
		return
	}

	rows, err := a.db.Query("SELECT id, protocol, peer, password, hashes, name FROM configs ORDER BY id DESC")
	if err != nil {
		return
	}
	defer rows.Close()

	var configs []Config
	for rows.Next() {
		var c Config
		rows.Scan(&c.ID, &c.Protocol, &c.Peer, &c.Password, &c.Hashes, &c.Name)
		configs = append(configs, c)
	}

	data, _ := json.Marshal(configs)
	if a.configsCallback != nil {
		a.configsCallback(string(data))
	}
}

// ============ API для JS ============

func (a *App) GetConfigsJson() string {
	if a.db == nil {
		return "[]"
	}

	rows, err := a.db.Query("SELECT id, protocol, peer, password, hashes, name FROM configs ORDER BY id DESC")
	if err != nil {
		return "[]"
	}
	defer rows.Close()

	var configs []Config
	for rows.Next() {
		var c Config
		rows.Scan(&c.ID, &c.Protocol, &c.Peer, &c.Password, &c.Hashes, &c.Name)
		configs = append(configs, c)
	}

	data, _ := json.Marshal(configs)
	return string(data)
}

func (a *App) GetSettingsJson() string {
	data, _ := json.Marshal(a.settings)
	return string(data)
}

func (a *App) GetLogsJson() string {
	a.mu.Lock()
	logs := append([]string{}, a.logs...)
	a.mu.Unlock()

	data, _ := json.Marshal(logs)
	return string(data)
}

func (a *App) SaveConfig(link string) bool {
	config := parseCsqttLink(link)

	_, err := a.db.Exec(
		"INSERT INTO configs (protocol, peer, password, hashes, name) VALUES (?, ?, ?, ?, ?)",
		config.Protocol, config.Peer, config.Password, config.Hashes, config.Name,
	)
	if err != nil {
		return false
	}

	a.loadConfigs()
	return true
}

func (a *App) DeleteConfig(id int64) bool {
	_, err := a.db.Exec("DELETE FROM configs WHERE id = ?", id)
	if err != nil {
		return false
	}
	a.loadConfigs()
	return true
}

func (a *App) SaveSettings(settingsJson string) bool {
	var newSettings Settings
	if err := json.Unmarshal([]byte(settingsJson), &newSettings); err != nil {
		return false
	}

	if newSettings.DeviceId == "" {
		newSettings.DeviceId = a.settings.DeviceId
	}
	if newSettings.DeviceId == "" {
		newSettings.DeviceId = uuid.New().String()
	}

	a.settings = newSettings
	a.saveSettingsFile()
	return true
}

func (a *App) Connect(configId int64) bool {
	config := a.getConfigByID(configId)
	if config == nil {
		a.addLog("[ERROR] Конфиг не найден")
		return false
	}

	a.addLog(fmt.Sprintf("[INFO] Подключаюсь к: %s", config.Name))
	a.addLog(fmt.Sprintf("[INFO] Peer: %s", config.Peer))

	go a.connectWorkerWithConfig(*config)
	return true
}

func (a *App) Disconnect() bool {
	a.mu.Lock()
	defer a.mu.Unlock()

	a.isConnected = false
	a.stopTunnel()

	if a.coreProcess != nil && a.coreProcess.Process != nil {
		a.coreProcess.Process.Kill()
		a.coreProcess = nil
	}

	if a.statusCallback != nil {
		a.statusCallback(false)
	}
	a.addLog("Отключено")
	return true
}

func (a *App) ClearLogs() bool {
	a.mu.Lock()
	a.logs = []string{}
	a.mu.Unlock()
	a.addLog("=== Логи очищены ===")
	return true
}

func (a *App) UpdateCore() bool {
	if a.isConnected {
		a.addLog("[UPDATE] Сначала отключитесь")
		return false
	}

	go a.updateCoreWorker()
	return true
}

func (a *App) SetLogCallback(callback func(string)) {
	a.logCallback = callback
}

func (a *App) SetStatusCallback(callback func(bool)) {
	a.statusCallback = callback
}

func (a *App) SetConfigsCallback(callback func(string)) {
	a.configsCallback = callback
}

func (a *App) SetUpdateCallback(callback func(string)) {
	a.updateCallback = callback
}

// ============ TUN методы ============

func (a *App) setupTun() error {
	a.mu.Lock()
	defer a.mu.Unlock()

	if a.tunSetupDone {
		return nil
	}

	if a.tun == nil {
		return fmt.Errorf("TUN интерфейс не инициализирован")
	}

	if err := a.tun.Setup(); err != nil {
		return err
	}

	a.tunSetupDone = true
	return nil
}

func (a *App) startTunnel(corePort int) {
	a.mu.Lock()
	if a.tunRunning {
		a.mu.Unlock()
		return
	}
	a.mu.Unlock()

	udpConn, err := net.Dial("udp", fmt.Sprintf("127.0.0.1:%d", corePort))
	if err != nil {
		a.addLog(fmt.Sprintf("[TUN] UDP ошибка: %v", err))
		return
	}

	a.mu.Lock()
	a.udpConn = udpConn
	a.tunRunning = true
	a.mu.Unlock()

	if a.tun != nil {
		a.tun.Start(udpConn, &a.tunRunning)
	}

	a.addLog("[TUN] Пакетный мост запущен")
}

func (a *App) stopTunnel() {
	a.mu.Lock()
	a.tunRunning = false
	a.mu.Unlock()

	if a.udpConn != nil {
		a.udpConn.Close()
		a.udpConn = nil
	}

	if a.tun != nil {
		a.tun.Stop()
	}

	a.mu.Lock()
	a.tunSetupDone = false
	a.mu.Unlock()
}

func (a *App) setupRoutes(tunIP string, tunDNS string) {
	if a.tun != nil {
		a.tun.SetupRoutes(tunIP, tunDNS)
		a.addLog("[TUN] Маршруты и DNS настроены")
	}
}

func (a *App) cleanupRoutes() {
	if a.tun != nil {
		a.tun.CleanupRoutes()
	}
}

// ============ Внутренние методы ============

func (a *App) addLog(message string) {
	fmt.Println(message)

	a.mu.Lock()
	a.logs = append(a.logs, message)
	if len(a.logs) > 500 {
		a.logs = a.logs[1:]
	}
	a.mu.Unlock()

	if a.logCallback != nil {
		a.logCallback(message)
	}
}

func parseCsqttLink(link string) Config {
	config := Config{
		Protocol: "CSQTT",
		Name:     "Config",
	}

	link = strings.TrimSpace(link)
	if !strings.HasPrefix(strings.ToLower(link), "csqtt://") {
		config.Peer = link
		return config
	}

	parsed, err := url.Parse(link)
	if err != nil {
		config.Peer = link
		return config
	}

	params := parsed.Query()

	if strings.ToLower(parsed.Hostname()) == "connect" {
		version := params.Get("v")
		if version != "2" {
			config.Peer = link
			return config
		}

		host := params.Get("host")
		port := params.Get("peer")
		password := params.Get("password")

		if host == "" || port == "" || password == "" {
			config.Peer = link
			return config
		}

		config.Peer = fmt.Sprintf("%s:%s", host, port)
		config.Password = password

		if hashes := params.Get("hashes"); hashes != "" {
			parts := strings.Split(hashes, "+")
			var clean []string
			for _, p := range parts {
				if p != "" {
					clean = append(clean, p)
				}
			}
			config.Hashes = strings.Join(clean, ",")
		}

		config.Name = config.Peer
	} else {
		host := parsed.Hostname()
		port := parsed.Port()
		if port == "" {
			port = "46000"
		}
		password := parsed.User.Username()

		if host == "" || password == "" {
			config.Peer = link
			return config
		}

		config.Peer = fmt.Sprintf("%s:%s", host, port)
		config.Password = password
		config.Name = config.Peer
	}

	return config
}

func (a *App) checkUpdateBackground() {
	remoteVersion := a.fetchLatestVersion()
	if remoteVersion == "" {
		return
	}

	localVersion := ""
	if data, err := os.ReadFile(a.latestFile); err == nil {
		localVersion = strings.TrimSpace(string(data))
	}

	if remoteVersion != localVersion {
		fmt.Printf("[UPDATE] Доступна новая версия: %s\n", remoteVersion)
		if a.updateCallback != nil {
			a.updateCallback(remoteVersion)
		}

		if !a.isConnected {
			go a.performUpdate(remoteVersion)
		}
	}
}

func (a *App) fetchLatestVersion() string {
	data := fetchURL(LATEST_URL)
	if data == nil {
		return ""
	}

	version := strings.TrimSpace(string(data))
	version = strings.ReplaceAll(version, "\n", "")
	version = strings.ReplaceAll(version, "\r", "")

	if version == "" ||
		strings.Contains(version, "Server error") ||
		strings.Contains(version, "No connection adapters") ||
		strings.Contains(version, "curl error") {
		return ""
	}

	return version
}

func (a *App) updateCoreWorker() {
	remoteVersion := a.fetchLatestVersion()
	if remoteVersion == "" {
		a.addLog("[UPDATE] Не удалось проверить версию")
		return
	}
	a.performUpdate(remoteVersion)
}

func (a *App) performUpdate(version string) {
	if a.isDownloading {
		return
	}

	a.isDownloading = true
	defer func() { a.isDownloading = false }()

	version = strings.TrimSpace(version)
	a.addLog(fmt.Sprintf("[UPDATE] Скачивание ядра версии %s...", version))

	coreURL := fmt.Sprintf(CORE_URL_TEMPLATE, version, a.getCoreFilename())
	tempCore := a.corePath + ".tmp"

	if !downloadFile(coreURL, tempCore) {
		a.addLog("[UPDATE] Ошибка скачивания ядра")
		os.Remove(tempCore)
		return
	}

	if _, err := os.Stat(a.corePath); err == nil {
		os.Remove(a.corePath)
	}
	os.Rename(tempCore, a.corePath)

	if runtime.GOOS != "windows" {
		os.Chmod(a.corePath, 0755)
	}

	os.WriteFile(a.latestFile, []byte(version), 0644)

	a.addLog(fmt.Sprintf("[UPDATE] Ядро обновлено до версии %s", version))
}

func (a *App) ensureWintun() bool {
	if runtime.GOOS != "windows" {
		return true
	}

	if _, err := os.Stat(a.wintunPath); err == nil {
		return true
	}

	a.addLog("[WINTUN] Скачивание wintun.dll...")

	tempZip := filepath.Join(a.appDir, "wintun.zip")
	if !downloadFile(WINTUN_URL, tempZip) {
		a.addLog("[WINTUN] Ошибка скачивания")
		os.Remove(tempZip)
		return false
	}

	cmd := exec.Command("powershell", "-Command",
		fmt.Sprintf("Expand-Archive -Path '%s' -DestinationPath '%s' -Force; Copy-Item '%s/wintun/bin/amd64/wintun.dll' '%s'",
			tempZip, filepath.Join(a.appDir, "wintun_tmp"), filepath.Join(a.appDir, "wintun_tmp"), a.wintunPath))
	cmd.Run()

	os.Remove(tempZip)
	os.RemoveAll(filepath.Join(a.appDir, "wintun_tmp"))

	if _, err := os.Stat(a.wintunPath); err == nil {
		a.addLog("[WINTUN] Готово")
		return true
	}

	return false
}

func (a *App) getConfigByID(id int64) *Config {
	row := a.db.QueryRow("SELECT id, protocol, peer, password, hashes, name FROM configs WHERE id = ?", id)
	var c Config
	if err := row.Scan(&c.ID, &c.Protocol, &c.Peer, &c.Password, &c.Hashes, &c.Name); err != nil {
		return nil
	}
	return &c
}

func runAsAdminWithBat(batPath string) error {
	verb, _ := syscall.UTF16PtrFromString("runas")
	file, _ := syscall.UTF16PtrFromString("cmd")
	params, _ := syscall.UTF16PtrFromString(fmt.Sprintf("/c \"%s\"", batPath))

	sei := shellExecuteInfo{
		cbSize:       uint32(unsafe.Sizeof(shellExecuteInfo{})),
		fMask:        SEE_MASK_NOCLOSEPROCESS,
		lpVerb:       verb,
		lpFile:       file,
		lpParameters: params,
		nShow:        SW_HIDE,
	}

	ret, _, _ := procShellExecEx.Call(uintptr(unsafe.Pointer(&sei)))
	if ret == 0 {
		return fmt.Errorf("ShellExecuteEx failed")
	}

	return nil
}

func (a *App) parseTunconf(line string) (string, string) {
	// Формат 1: TUNCONF:10.66.67.12:8.8.8.8,8.8.4.4:64787
	if strings.HasPrefix(line, "TUNCONF:") {
		tunconf := strings.TrimPrefix(line, "TUNCONF:")
		parts := strings.Split(tunconf, ":")
		if len(parts) >= 2 {
			return parts[0], parts[1]
		}
	}

	// Формат 2: [КЛИЕНТ] Tunnel IP: 10.66.67.12/32 | DNS: 8.8.8.8,8.8.4.4
	if strings.Contains(line, "Tunnel IP:") && strings.Contains(line, "DNS:") {
		ipIdx := strings.Index(line, "Tunnel IP:")
		dnsIdx := strings.Index(line, "DNS:")

		if ipIdx >= 0 && dnsIdx > ipIdx {
			ipPart := strings.TrimSpace(line[ipIdx+10 : dnsIdx])
			ipPart = strings.TrimSpace(strings.TrimSuffix(ipPart, "|"))
			ipPart = strings.TrimSpace(ipPart)

			// Отрезаем /32
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

func (a *App) connectWorkerWithConfig(config Config) {
	wintunDone := make(chan bool, 1)
	go func() {
		if runtime.GOOS == "windows" {
			if !a.ensureWintun() {
				a.addLog("[ERROR] Не удалось получить wintun.dll")
				wintunDone <- false
				return
			}
		}
		wintunDone <- true
	}()

	coreDone := make(chan bool, 1)
	go func() {
		if _, err := os.Stat(a.corePath); os.IsNotExist(err) {
			a.addLog("[API] Ядро не найдено, скачиваю...")
			remoteVersion := a.fetchLatestVersion()
			if remoteVersion == "" {
				a.addLog("[ERROR] Не удалось получить версию")
				coreDone <- false
				return
			}
			a.performUpdate(remoteVersion)

			if _, err := os.Stat(a.corePath); os.IsNotExist(err) {
				a.addLog("[ERROR] Не удалось скачать ядро")
				coreDone <- false
				return
			}
		}
		coreDone <- true
	}()

	if !<-wintunDone {
		return
	}
	if !<-coreDone {
		return
	}

	a.addLog(fmt.Sprintf("=== Подключение к %s ===", config.Name))

	listenPort := getFreePort()
	cmdArgs := a.buildCommand(&config, listenPort)
	a.addLog(fmt.Sprintf("Команда: %s", strings.Join(cmdArgs, " ")))

	a.mu.Lock()
	a.isConnected = true
	a.mu.Unlock()

	if a.statusCallback != nil {
		a.statusCallback(true)
	}

	if runtime.GOOS == "windows" {
		logFile := filepath.Join(os.TempDir(), "csqtt_core_logs.txt")
		batPath := filepath.Join(os.TempDir(), "lalune_start_core.bat")

		os.Remove(logFile)

		quotedArgs := make([]string, len(cmdArgs)-1)
		for i, arg := range cmdArgs[1:] {
			quotedArgs[i] = "\"" + strings.ReplaceAll(arg, "\"", "\\\"") + "\""
		}

		batContent := fmt.Sprintf("@echo off\r\n\"%s\" %s > \"%s\" 2>&1\r\n",
			cmdArgs[0],
			strings.Join(quotedArgs, " "),
			logFile,
		)

		os.WriteFile(batPath, []byte(batContent), 0644)

		err := runAsAdminWithBat(batPath)
		if err != nil {
			a.addLog(fmt.Sprintf("[ERROR] Не удалось запустить от админа: %v", err))
			a.mu.Lock()
			a.isConnected = false
			a.mu.Unlock()
			if a.statusCallback != nil {
				a.statusCallback(false)
			}
			return
		}
		a.addLog("[INFO] Ядро запущено от администратора")

		go func() {
			for a.isConnected {
				if data, err := os.ReadFile(logFile); err == nil {
					content := string(data)
					if content != "" {
						lines := strings.Split(content, "\n")
						for _, line := range lines {
							line = strings.TrimSpace(line)
							if line == "" {
								continue
							}

							a.addLog(line)

							tunIP, tunDNS := a.parseTunconf(line)
							if tunIP != "" && tunDNS != "" {
								a.addLog(fmt.Sprintf("[TUN] IP: %s, DNS: %s", tunIP, tunDNS))

								go func() {
									if err := a.setupTun(); err == nil {
										a.setupRoutes(tunIP, tunDNS)
										a.startTunnel(listenPort)
									} else {
										a.addLog(fmt.Sprintf("[TUN] Ошибка: %v", err))
									}
								}()
							}
						}
						os.Truncate(logFile, 0)
					}
				}
				time.Sleep(1 * time.Second)
			}

			a.stopTunnel()
			a.cleanupRoutes()
		}()
	} else {
		coreCmd := exec.Command(cmdArgs[0], cmdArgs[1:]...)
		coreCmd.Env = append(os.Environ(),
			"CSQTT_EVENTS=1",
			fmt.Sprintf("TOKIO_WORKER_THREADS=%d", minInt(runtime.NumCPU(), 8)),
			"RAYON_NUM_THREADS=2",
		)

		stdout, err := coreCmd.StdoutPipe()
		if err != nil {
			a.addLog(fmt.Sprintf("[ERROR] %v", err))
			return
		}

		if err := coreCmd.Start(); err != nil {
			a.addLog(fmt.Sprintf("[ERROR] %v", err))
			return
		}

		a.mu.Lock()
		a.coreProcess = coreCmd
		a.mu.Unlock()

		go func() {
			scanner := bufio.NewScanner(stdout)
			scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
			for scanner.Scan() {
				line := strings.TrimSpace(scanner.Text())
				if line == "" {
					continue
				}

				a.addLog(line)

				tunIP, tunDNS := a.parseTunconf(line)
				if tunIP != "" && tunDNS != "" {
					a.addLog(fmt.Sprintf("[TUN] IP: %s, DNS: %s", tunIP, tunDNS))

					go func() {
						if err := a.setupTun(); err == nil {
							a.setupRoutes(tunIP, tunDNS)
							a.startTunnel(listenPort)
						} else {
							a.addLog(fmt.Sprintf("[TUN] Ошибка: %v", err))
						}
					}()
				}
			}
		}()

		go func() {
			coreCmd.Wait()
			a.stopTunnel()
			a.cleanupRoutes()
			a.mu.Lock()
			a.isConnected = false
			a.coreProcess = nil
			a.mu.Unlock()
			if a.statusCallback != nil {
				a.statusCallback(false)
			}
			a.addLog("=== Процесс завершён ===")
		}()
	}
}

func (a *App) buildCommand(config *Config, listenPort int) []string {
	hashesList := strings.Split(config.Hashes, ",")
	hashesCount := 0
	for _, h := range hashesList {
		if strings.TrimSpace(h) != "" {
			hashesCount++
		}
	}
	if hashesCount > 6 {
		hashesCount = 6
	}
	if hashesCount < 1 {
		hashesCount = 1
	}

	workersPerHash := a.settings.WorkersPerHash
	if workersPerHash < 9 {
		workersPerHash = 9
	}
	totalWorkers := workersPerHash * hashesCount

	cmd := []string{
		a.corePath,
		"-peer", config.Peer,
		"-n", fmt.Sprintf("%d", totalWorkers),
		"-listen", fmt.Sprintf("127.0.0.1:%d", listenPort),
		"-vk", config.Hashes,
		"-fingerprint", a.settings.Fingerprint,
		"-client-ids", a.settings.ClientIds,
		"-obfs", a.settings.Obfs,
		"-vk-auth-mode", a.settings.VkAuthMode,
		"-device-id", a.settings.DeviceId,
		"-password", config.Password,
		"-captcha-mode", a.settings.CaptchaMode,
	}

	if a.settings.TurnHost != "" {
		cmd = append(cmd, "-turn", a.settings.TurnHost)
	}
	if a.settings.TurnPort != "" {
		cmd = append(cmd, "-port", a.settings.TurnPort)
	}

	return cmd
}

// ============ Утилиты ============

func fetchURL(urlStr string) []byte {
	urlStr = strings.TrimSpace(urlStr)
	urls := []string{
		urlStr,
		PROXY_URL + url.QueryEscape(urlStr),
	}

	for _, attemptURL := range urls {
		fmt.Printf("[NET] Пробую: %s...\n", attemptURL[:minInt(100, len(attemptURL))])

		client := &http.Client{Timeout: HTTP_TIMEOUT}
		req, _ := http.NewRequest("GET", attemptURL, nil)
		req.Header.Set("User-Agent", USER_AGENT)

		resp, err := client.Do(req)
		if err != nil {
			fmt.Printf("[NET] Ошибка: %v\n", err)
			continue
		}

		data, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			continue
		}

		if resp.StatusCode != 200 {
			continue
		}

		content := string(data)
		if strings.Contains(content, "No connection adapters") ||
			strings.Contains(content, "Server error") {
			continue
		}

		return data
	}

	return nil
}

func downloadFile(urlStr string, destination string) bool {
	urlStr = strings.TrimSpace(urlStr)
	urls := []string{
		urlStr,
		PROXY_URL + url.QueryEscape(urlStr),
	}

	for _, attemptURL := range urls {
		fmt.Printf("[DOWNLOAD] Пробую: %s...\n", attemptURL[:minInt(100, len(attemptURL))])

		client := &http.Client{Timeout: HTTP_TIMEOUT}
		req, _ := http.NewRequest("GET", attemptURL, nil)
		req.Header.Set("User-Agent", USER_AGENT)

		resp, err := client.Do(req)
		if err != nil {
			continue
		}

		if resp.StatusCode != 200 {
			resp.Body.Close()
			continue
		}

		file, err := os.Create(destination)
		if err != nil {
			resp.Body.Close()
			continue
		}

		_, err = io.Copy(file, resp.Body)
		file.Close()
		resp.Body.Close()

		if err != nil {
			os.Remove(destination)
			continue
		}

		info, err := os.Stat(destination)
		if err != nil || info.Size() < 1024 {
			os.Remove(destination)
			continue
		}

		return true
	}

	return false
}

func getFreePort() int {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 9000
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
