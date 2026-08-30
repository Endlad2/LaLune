package main

import (
	"archive/zip"
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/songgao/water"
)

const (
	LATEST_URL        = "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST"
	CORE_URL_TEMPLATE = "https://github.com/Endlad2/csqtt-core/releases/download/%s/%s"
	LALUNE_ZIP_URL    = "https://github.com/Endlad2/LaLune/archive/refs/heads/main.zip"
	PROXY_URL         = "http://31.77.148.203:8855/?url="
	USER_AGENT        = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
	HTTP_TIMEOUT      = 15 * time.Second
	LISTEN_PORT       = 9988
)

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

type App struct {
	mu           sync.Mutex
	isConnected  bool
	coreProcess  *exec.Cmd
	configs      []Config
	settings     Settings
	logs         []string
	settingsFile string
	configsFile  string
	latestFile   string
	corePath     string
	tunIface     *water.Interface
	udpConn      net.Conn
	tunRunning   bool
}

func NewApp() *App {
	return &App{
		logs: []string{},
	}
}

func (a *App) init() {
	dataDir := "/etc/lalune"
	if runtime.GOOS == "windows" {
		home, _ := os.UserHomeDir()
		dataDir = filepath.Join(home, ".la-lune")
	}
	os.MkdirAll(dataDir, 0755)

	a.settingsFile = filepath.Join(dataDir, "settings.json")
	a.configsFile = filepath.Join(dataDir, "configs.json")
	a.latestFile = filepath.Join(dataDir, "LATEST")

	if runtime.GOOS == "windows" {
		a.corePath = filepath.Join(dataDir, a.getPlatform())
	} else {
		a.corePath = filepath.Join(os.TempDir(), a.getPlatform())
	}

	a.loadSettings()
	a.loadConfigs()
}

func (a *App) getPlatform() string {
	output, err := exec.Command("uname", "-m").Output()
	if err != nil {
		return "client-windows-x86_64.exe"
	}

	uname := strings.TrimSpace(string(output))

	if strings.Contains(uname, "aarch64") {
		return "client-linux-arm64"
	} else if strings.Contains(uname, "armv7") || strings.Contains(uname, "armv7l") {
		return "client-linux-armv7"
	} else if strings.Contains(uname, "x86_64") {
		return "client-linux-x86_64"
	}

	return "client-linux-armv7"
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
			DeviceId:       generateDeviceID(),
		}
		a.saveSettings()
		return
	}

	json.Unmarshal(data, &a.settings)

	if a.settings.DeviceId == "" {
		a.settings.DeviceId = generateDeviceID()
		a.saveSettings()
	}
}

func (a *App) saveSettings() {
	data, _ := json.MarshalIndent(a.settings, "", "  ")
	os.WriteFile(a.settingsFile, data, 0644)
}

func (a *App) loadConfigs() {
	data, err := os.ReadFile(a.configsFile)
	if err != nil {
		a.configs = []Config{}
		os.WriteFile(a.configsFile, []byte("[]"), 0644)
		return
	}

	json.Unmarshal(data, &a.configs)
}

func (a *App) saveConfigs() {
	data, _ := json.MarshalIndent(a.configs, "", "  ")
	os.WriteFile(a.configsFile, data, 0644)
}

func generateDeviceID() string {
	b := make([]byte, 16)
	for i := range b {
		b[i] = byte(time.Now().UnixNano() >> (i * 4) & 0xFF)
	}
	return fmt.Sprintf("%x", b)
}

func (a *App) addLog(message string) {
	fmt.Println(message)

	a.mu.Lock()
	a.logs = append(a.logs, message)
	if len(a.logs) > 500 {
		a.logs = a.logs[1:]
	}
	a.mu.Unlock()
}

func (a *App) getLogs() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]string{}, a.logs...)
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

	rest := strings.TrimPrefix(link, "csqtt://")
	parts := strings.SplitN(rest, "?", 2)
	host := parts[0]

	if strings.EqualFold(host, "connect") && len(parts) == 2 {
		query := parts[1]
		params := make(map[string]string)
		for _, p := range strings.Split(query, "&") {
			kv := strings.SplitN(p, "=", 2)
			if len(kv) == 2 {
				params[kv[0]] = kv[1]
			}
		}

		peerHost := params["host"]
		peerPort := params["peer"]
		password := params["password"]

		if peerHost != "" && peerPort != "" && password != "" {
			config.Peer = fmt.Sprintf("%s:%s", peerHost, peerPort)
			config.Password = password

			if hashes, ok := params["hashes"]; ok {
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
		}
	} else {
		parts := strings.Split(rest, "@")
		if len(parts) == 2 {
			config.Password = parts[0]
			config.Peer = parts[1]
			config.Name = parts[1]
		}
	}

	return config
}

func fetchURL(urlStr string) []byte {
	urlStr = strings.TrimSpace(urlStr)
	urls := []string{
		urlStr,
		PROXY_URL + urlStr,
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
		PROXY_URL + urlStr,
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

		fmt.Printf("[DOWNLOAD] Success: %s (%d bytes)\n", destination, info.Size())
		return true
	}

	return false
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
		strings.Contains(version, "No connection adapters") {
		return ""
	}

	return version
}

func (a *App) updateCore() bool {
	version := a.fetchLatestVersion()
	if version == "" {
		a.addLog("[UPDATE] Ошибка: не удалось получить LATEST")
		return false
	}

	localVersion := ""
	if data, err := os.ReadFile(a.latestFile); err == nil {
		localVersion = strings.TrimSpace(string(data))
	}

	if version == localVersion {
		if _, err := os.Stat(a.corePath); err == nil {
			return true
		}
	}

	a.addLog(fmt.Sprintf("[UPDATE] Скачиваю ядро v%s...", version))

	coreURL := fmt.Sprintf(CORE_URL_TEMPLATE, version, a.getPlatform())

	if downloadFile(coreURL, a.corePath) {
		if runtime.GOOS != "windows" {
			os.Chmod(a.corePath, 0755)
		}
		os.WriteFile(a.latestFile, []byte(version), 0644)
		a.addLog(fmt.Sprintf("[UPDATE] Ядро v%s готово", version))
		return true
	}

	a.addLog("[UPDATE] Ошибка скачивания ядра")
	return false
}

func (a *App) buildCommand(config *Config) ([]string, int) {
	hashesCount := 1
	if config.Hashes != "" {
		hashesCount = len(strings.Split(config.Hashes, ","))
	}
	if hashesCount > 6 {
		hashesCount = 6
	}

	workersPerHash := a.settings.WorkersPerHash
	if workersPerHash < 9 {
		workersPerHash = 9
	}

	totalWorkers := workersPerHash * hashesCount

	port := getFreePort()

	cmd := []string{
		a.corePath,
		"-peer", config.Peer,
		"-n", fmt.Sprintf("%d", totalWorkers),
		"-listen", fmt.Sprintf("127.0.0.1:%d", port),
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

	return cmd, port
}

func getFreePort() int {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 9000
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

func (a *App) setupTun(tunIP string, tunDNS string) {
	a.mu.Lock()
	if a.tunRunning {
		a.mu.Unlock()
		return
	}
	a.mu.Unlock()

	// Создаём TUN
	config := water.Config{
		DeviceType: water.TUN,
	}
	config.Name = "csqtt0"

	iface, err := water.New(config)
	if err != nil {
		a.addLog(fmt.Sprintf("[TUN] Ошибка создания: %v", err))
		return
	}

	a.mu.Lock()
	a.tunIface = iface
	a.tunRunning = true
	a.mu.Unlock()

	a.addLog(fmt.Sprintf("[TUN] Устройство: %s", iface.Name()))

	// Настраиваем IP
	exec.Command("ip", "addr", "add", tunIP+"/32", "dev", iface.Name()).Run()
	exec.Command("ip", "link", "set", iface.Name(), "up").Run()
	exec.Command("ip", "link", "set", iface.Name(), "mtu", "1300").Run()

	// DNS
	dnsServers := strings.Split(tunDNS, ",")
	for i, dns := range dnsServers {
		if dns != "" && i < 2 {
			exec.Command("sh", "-c", fmt.Sprintf("echo 'nameserver %s' > /etc/resolv.conf", dns)).Run()
		}
	}

	// Маршрут
	exec.Command("ip", "route", "add", "default", "dev", iface.Name()).Run()

	a.addLog("[TUN] Маршруты и DNS настроены")
}

func (a *App) startTunnel(corePort int) {
	// UDP сокет к ядру
	udpConn, err := net.Dial("udp", fmt.Sprintf("127.0.0.1:%d", corePort))
	if err != nil {
		a.addLog(fmt.Sprintf("[TUN] UDP ошибка: %v", err))
		return
	}

	a.mu.Lock()
	a.udpConn = udpConn
	iface := a.tunIface
	a.mu.Unlock()

	if iface == nil {
		a.addLog("[TUN] Интерфейс ещё не создан")
		return
	}

	// TUN → UDP
	go func() {
		buf := make([]byte, 65535)
		for {
			n, err := iface.Read(buf)
			if err != nil {
				return
			}
			udpConn.Write(buf[:n])
		}
	}()

	// UDP → TUN
	go func() {
		buf := make([]byte, 65535)
		for {
			n, err := udpConn.Read(buf)
			if err != nil {
				return
			}
			iface.Write(buf[:n])
		}
	}()

	a.addLog("[TUN] Пакетный мост запущен")
}

func (a *App) stopTunnel() {
	a.mu.Lock()
	defer a.mu.Unlock()

	a.tunRunning = false

	if a.tunIface != nil {
		a.tunIface.Close()
		a.tunIface = nil
	}

	if a.udpConn != nil {
		a.udpConn.Close()
		a.udpConn = nil
	}
}

func (a *App) connect(configID int64) bool {
	var config *Config
	for i := range a.configs {
		if a.configs[i].ID == configID {
			config = &a.configs[i]
			break
		}
	}

	if config == nil {
		a.addLog("[ERROR] Конфиг не найден")
		return false
	}

	if !a.updateCore() {
		return false
	}

	cmdArgs, corePort := a.buildCommand(config)
	a.addLog(fmt.Sprintf("Команда: %s", strings.Join(cmdArgs, " ")))
	a.addLog(fmt.Sprintf("[TUN] Порт ядра: %d", corePort))

	coreCmd := exec.Command(cmdArgs[0], cmdArgs[1:]...)
	stdout, err := coreCmd.StdoutPipe()
	if err != nil {
		a.addLog(fmt.Sprintf("[ERROR] %v", err))
		return false
	}

	if err := coreCmd.Start(); err != nil {
		a.addLog(fmt.Sprintf("[ERROR] %v", err))
		return false
	}

	a.mu.Lock()
	a.coreProcess = coreCmd
	a.isConnected = true
	a.mu.Unlock()

	a.addLog(fmt.Sprintf("=== Подключено к %s ===", config.Name))

	// Читаем stdout — парсим TUNCONF
	go func() {
		reader := bufio.NewReader(stdout)
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				break
			}

			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}

			a.addLog(line)

			// Ищем TUNCONF
			if strings.HasPrefix(line, "TUNCONF:") {
				tunconf := strings.TrimPrefix(line, "TUNCONF:")
				parts := strings.Split(tunconf, ":")
				if len(parts) >= 2 {
					tunIP := parts[0]
					tunDNS := parts[1]

					a.addLog(fmt.Sprintf("[TUN] IP: %s, DNS: %s", tunIP, tunDNS))

					// Создаём TUN и настраиваем
					go a.setupTun(tunIP, tunDNS)

					// Запускаем мост
					go func() {
						time.Sleep(1 * time.Second)
						a.startTunnel(corePort)
					}()
				}
			}
		}
	}()

	// Ждём завершения
	go func() {
		coreCmd.Wait()
		a.stopTunnel()
		a.mu.Lock()
		a.isConnected = false
		a.coreProcess = nil
		a.mu.Unlock()
		a.addLog("=== Процесс завершён ===")
	}()

	return true
}

func (a *App) disconnect() {
	a.mu.Lock()
	defer a.mu.Unlock()

	a.isConnected = false
	a.tunRunning = false

	if a.coreProcess != nil && a.coreProcess.Process != nil {
		a.coreProcess.Process.Kill()
		a.coreProcess = nil
	}

	if a.tunIface != nil {
		a.tunIface.Close()
		a.tunIface = nil
	}

	if a.udpConn != nil {
		a.udpConn.Close()
		a.udpConn = nil
	}

	a.addLog("Отключено")
}

func detectLANIP() string {
	for _, iface := range []string{"br0", "br-lan"} {
		output, err := exec.Command("ip", "addr", "show", "dev", iface).Output()
		if err != nil {
			continue
		}

		for _, line := range strings.Split(string(output), "\n") {
			if strings.Contains(line, "inet ") {
				parts := strings.Fields(line)
				if len(parts) >= 2 {
					ip := parts[1]
					if idx := strings.Index(ip, "/"); idx >= 0 {
						ip = ip[:idx]
					}
					return ip
				}
			}
		}
	}

	return "127.0.0.1"
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func (a *App) downloadAndExtractFrontend() error {
	if _, err := os.Stat("LaLune-main"); err == nil {
		fmt.Println("[FRONTEND] Уже скачан")
		return nil
	}

	fmt.Println("[FRONTEND] Скачиваю LaLune-main.zip...")

	zipPath := filepath.Join(os.TempDir(), "lalune-main.zip")
	if !downloadFile(LALUNE_ZIP_URL, zipPath) {
		return fmt.Errorf("не удалось скачать frontend")
	}

	fmt.Println("[FRONTEND] Распаковываю...")

	reader, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer reader.Close()

	for _, file := range reader.File {
		path := filepath.Join(".", file.Name)

		if file.FileInfo().IsDir() {
			os.MkdirAll(path, 0755)
			continue
		}

		os.MkdirAll(filepath.Dir(path), 0755)

		dst, err := os.Create(path)
		if err != nil {
			continue
		}

		src, err := file.Open()
		if err != nil {
			dst.Close()
			continue
		}

		io.Copy(dst, src)
		dst.Close()
		src.Close()
	}

	os.Remove(zipPath)

	fmt.Println("[FRONTEND] Готово")
	return nil
}

// ============ HTTP Handlers ============

func (a *App) handleConfigs(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	switch r.Method {
	case "GET":
		json.NewEncoder(w).Encode(map[string]interface{}{
			"success": true,
			"configs": a.configs,
		})

	case "POST":
		var req struct {
			Link string `json:"link"`
		}
		json.NewDecoder(r.Body).Decode(&req)

		config := parseCsqttLink(req.Link)

		a.mu.Lock()
		config.ID = int64(len(a.configs) + 1)
		a.configs = append(a.configs, config)
		a.saveConfigs()
		a.mu.Unlock()

		json.NewEncoder(w).Encode(map[string]interface{}{
			"success": true,
		})

	default:
		http.Error(w, "Method not allowed", 405)
	}
}

func (a *App) handleConfigByID(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	idStr := strings.TrimPrefix(r.URL.Path, "/api/configs/")
	var id int64
	fmt.Sscanf(idStr, "%d", &id)

	if r.Method == "DELETE" {
		a.mu.Lock()
		newConfigs := []Config{}
		for _, c := range a.configs {
			if c.ID != id {
				newConfigs = append(newConfigs, c)
			}
		}
		a.configs = newConfigs
		a.saveConfigs()
		a.mu.Unlock()

		json.NewEncoder(w).Encode(map[string]interface{}{
			"success": true,
		})
		return
	}

	http.Error(w, "Method not allowed", 405)
}

func (a *App) handleSettings(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	switch r.Method {
	case "GET":
		json.NewEncoder(w).Encode(map[string]interface{}{
			"success":  true,
			"settings": a.settings,
		})

	case "POST":
		var req struct {
			Settings Settings `json:"settings"`
		}
		json.NewDecoder(r.Body).Decode(&req)

		a.mu.Lock()
		if req.Settings.DeviceId == "" {
			req.Settings.DeviceId = a.settings.DeviceId
		}
		a.settings = req.Settings
		a.saveSettings()
		a.mu.Unlock()

		json.NewEncoder(w).Encode(map[string]interface{}{
			"success": true,
		})

	default:
		http.Error(w, "Method not allowed", 405)
	}
}

func (a *App) handleConnect(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	var req struct {
		ConfigID int64 `json:"config_id"`
	}
	json.NewDecoder(r.Body).Decode(&req)

	success := a.connect(req.ConfigID)

	json.NewEncoder(w).Encode(map[string]interface{}{
		"success": success,
	})
}

func (a *App) handleDisconnect(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	a.disconnect()
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success": true,
	})
}

func (a *App) handleStatus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	a.mu.Lock()
	connected := a.isConnected
	a.mu.Unlock()

	json.NewEncoder(w).Encode(map[string]interface{}{
		"success":      true,
		"is_connected": connected,
	})
}

func (a *App) handleLogs(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method == "DELETE" {
		a.mu.Lock()
		a.logs = []string{}
		a.mu.Unlock()
		json.NewEncoder(w).Encode(map[string]interface{}{
			"success": true,
		})
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"success": true,
		"logs":    a.getLogs(),
	})
}

func main() {
	app := NewApp()
	app.init()

	// Скачиваем frontend
	app.downloadAndExtractFrontend()

	frontendDir := filepath.Join(".", "LaLune-main", "Frontend")

	mux := http.NewServeMux()

	// API
	mux.HandleFunc("/api/configs", app.handleConfigs)
	mux.HandleFunc("/api/configs/", app.handleConfigByID)
	mux.HandleFunc("/api/settings", app.handleSettings)
	mux.HandleFunc("/api/connect", app.handleConnect)
	mux.HandleFunc("/api/disconnect", app.handleDisconnect)
	mux.HandleFunc("/api/status", app.handleStatus)
	mux.HandleFunc("/api/logs", app.handleLogs)

	// Статика
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		if path == "/" {
			path = "/app.html"
		}

		path = strings.TrimPrefix(path, "/static/")

		filePath := filepath.Join(frontendDir, path)

		data, err := os.ReadFile(filePath)
		if err != nil {
			http.NotFound(w, r)
			return
		}

		// Заменяем плейсхолдеры
		content := string(data)
		content = strings.ReplaceAll(content, "{QTWEBCHANNEL_SCRIPT}", "")
		content = strings.ReplaceAll(content, "{API_SCRIPT}", "/static/openwrt-api.js")
		data = []byte(content)

		if strings.HasSuffix(path, ".html") {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
		} else if strings.HasSuffix(path, ".js") {
			w.Header().Set("Content-Type", "application/javascript")
		} else if strings.HasSuffix(path, ".css") {
			w.Header().Set("Content-Type", "text/css")
		}

		w.Write(data)
	})

	host := detectLANIP()
	bindAddr := fmt.Sprintf("%s:%d", host, LISTEN_PORT)

	fmt.Println("========================================")
	fmt.Println(" LaLune OpenWRT")
	fmt.Printf(" UI: http://%s/\n", bindAddr)
	fmt.Println("========================================")

	if err := http.ListenAndServe(bindAddr, mux); err != nil {
		fmt.Printf("[ERROR] %v\n", err)
		fmt.Println("[FALLBACK] Пробую 127.0.0.1:9988")
		http.ListenAndServe("127.0.0.1:9988", mux)
	}
}
