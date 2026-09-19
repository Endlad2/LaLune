// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune OpenWRT — встроенный веб-сервер с API и фронтендом.
//
// Фронтенд (Dart/Flutter Web) вкомпилирован в бинарник через //go:embed web.
// Папка OpenWRT/web заполняется на этапе сборки:
//   python build_frontend.py --platform OpenWRT
//   cp -r Frontend/output/. OpenWRT/web/
//
// Слушает на порту 6543:
//   GET  /                — отдаёт index.html + assets (Flutter/Dart-сборка)
//   GET  /api/status      — {"connected":bool,"installerRunning":bool,"coreRunning":bool}
//   GET  /api/configs     — массив конфигов
//   POST /api/configs     — {"link":"csqtt://..."} добавить
//   DEL  /api/configs?id= — удалить
//   GET  /api/settings    — настройки
//   POST /api/settings    — сохранить
//   GET  /api/logs        — массив строк лога ядра
//   POST /api/logs/clear  — очистить лог
//   POST /api/connect     — запустить установщик + ядро
//   POST /api/disconnect  — остановить
//   GET  /api/vktoken     — {"hasToken":bool,"fetcherOk":bool,...}
//   POST /api/vktoken     — {"token":"vk1.a..."} сохранить
//   DEL  /api/vktoken     — удалить
//   GET  /api/updates     — {"update":bool,"version":"..."}
//   POST /api/updates     — запустить обновление ядра
//
// Данные хранятся в /etc/csqtt/:
//   configs.json   — список конфигов
//   settings.json  — настройки
//   token.json     — VK-токен
//   csqtt.log      — лог ядра

package main

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	listenAddr    = ":6543"
	csqttDir      = "/etc/csqtt"
	configsFile   = "configs.json"
	settingsFile  = "settings.json"
	tokenFile     = "token.json"
	coreLogFile   = "csqtt.log"
	installerURL  = "https://raw.githubusercontent.com/redline-keen/csqtt-openwrt/main/csqtt-github-install-openwrt.sh"
	installerPath = "/tmp/csqtt-install.sh"
)

// embedFS — весь фронтенд (index.html, api.js, flutter_bootstrap.js, assets/...).
//
//go:embed all:web
var embedFS embed.FS

// ============================================================
//  Структуры
// ============================================================

type Config struct {
	ID       int64  `json:"id"`
	Protocol string `json:"protocol"`
	Peer     string `json:"peer"`
	Password string `json:"password"`
	Hashes   string `json:"hashes"`
	Name     string `json:"name"`
	RawLink  string `json:"rawLink"`
}

type Settings struct {
	AuthMode          string `json:"authMode"`   // "manual" | "autoVk"
	Workers           int    `json:"workers"`    // общее число воркеров
	VkAuthMode        string `json:"vkAuthMode"` // legacy
	Obfs              string `json:"obfs"`
	Fingerprint       string `json:"fingerprint"`
	ClientIds         string `json:"clientIds"`
	CaptchaMode       string `json:"captchaMode"`
	TurnTransport     string `json:"turnTransport"`
	DeviceID          string `json:"deviceId"`
	EnableSmartTunnel bool   `json:"enableSmartTunnel"`
}

type TokenFile struct {
	Token   string `json:"Token"`
	SavedAt string `json:"SavedAt"`
}

type App struct {
	mu               sync.RWMutex
	configs          []Config
	settings         Settings
	installer        *exec.Cmd
	corePID          int
	installerRunning bool
}

// ============================================================
//  main
// ============================================================

func main() {
	if err := os.MkdirAll(csqttDir, 0755); err != nil {
		log.Fatalf("[LaLune] не могу создать %s: %v", csqttDir, err)
	}

	app := &App{}
	app.loadConfigs()
	app.loadSettings()

	mux := http.NewServeMux()

	// --- статика из вкомпилированного фронтенда ---
	mux.HandleFunc("/", app.serveStatic)

	// --- api ---
	mux.HandleFunc("/api/status", app.handleStatus)
	mux.HandleFunc("/api/configs", app.handleConfigs)
	mux.HandleFunc("/api/settings", app.handleSettings)
	mux.HandleFunc("/api/logs", app.handleLogs)
	mux.HandleFunc("/api/logs/clear", app.handleLogsClear)
	mux.HandleFunc("/api/connect", app.handleConnect)
	mux.HandleFunc("/api/disconnect", app.handleDisconnect)
	mux.HandleFunc("/api/vktoken", app.handleVkToken)
	mux.HandleFunc("/api/updates", app.handleUpdates)

	srv := &http.Server{
		Addr:    listenAddr,
		Handler: mux,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		log.Printf("[LaLune] слушаю %s", listenAddr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[LaLune] ошибка сервера: %v", err)
		}
	}()

	<-stop
	log.Println("[LaLune] останавливаюсь...")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}

// ============================================================
//  Статика из embed.FS
// ============================================================

func (a *App) serveStatic(w http.ResponseWriter, r *http.Request) {
	// webFS — корень внутри embed.FS (убираем префикс "web/").
	webFS, err := fs.Sub(embedFS, "web")
	if err != nil {
		http.Error(w, "embed broken", http.StatusInternalServerError)
		return
	}

	path := r.URL.Path
	if path == "/" {
		path = "/index.html"
	}

	// SPA-fallback: если файла нет — отдаём index.html.
	f, err := webFS.Open(strings.TrimPrefix(path, "/"))
	if err != nil {
		f, err = webFS.Open("index.html")
		if err != nil {
			http.Error(w, "frontend not embedded", http.StatusNotFound)
			return
		}
		path = "/index.html"
	}
	_ = f.Close()

	// Заголовки кэширования/типов.
	switch {
	case strings.HasSuffix(path, ".js"):
		w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
	case strings.HasSuffix(path, ".html"):
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
	case strings.HasSuffix(path, ".css"):
		w.Header().Set("Content-Type", "text/css; charset=utf-8")
	case strings.HasSuffix(path, ".json"):
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
	case strings.HasSuffix(path, ".png"):
		w.Header().Set("Content-Type", "image/png")
	case strings.HasSuffix(path, ".jpg"), strings.HasSuffix(path, ".jpeg"):
		w.Header().Set("Content-Type", "image/jpeg")
	case strings.HasSuffix(path, ".svg"):
		w.Header().Set("Content-Type", "image/svg+xml")
	case strings.HasSuffix(path, ".wasm"):
		w.Header().Set("Content-Type", "application/wasm")
	}

	http.FileServer(http.FS(webFS)).ServeHTTP(w, r)
}

// ============================================================
//  /api/status
// ============================================================

func (a *App) handleStatus(w http.ResponseWriter, r *http.Request) {
	a.mu.RLock()
	defer a.mu.RUnlock()

	coreAlive := a.corePID > 0 && processAlive(a.corePID)
	writeJSON(w, map[string]interface{}{
		"connected":        coreAlive,
		"coreRunning":      coreAlive,
		"installerRunning": a.installerRunning,
	})
}

// ============================================================
//  /api/configs
// ============================================================

func (a *App) handleConfigs(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		a.mu.RLock()
		out := a.configs
		a.mu.RUnlock()
		if out == nil {
			out = []Config{}
		}
		writeJSON(w, out)

	case http.MethodPost:
		var req struct {
			Link string `json:"link"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			httpError(w, 400, "bad json")
			return
		}
		cfg := parseCsqttLink(req.Link)

		a.mu.Lock()
		cfg.ID = time.Now().UnixNano()
		a.configs = append(a.configs, cfg)
		a.saveConfigsLocked()
		a.mu.Unlock()

		writeJSON(w, map[string]interface{}{"ok": true, "id": cfg.ID})

	case http.MethodDelete:
		idStr := r.URL.Query().Get("id")
		id, _ := strconv.ParseInt(idStr, 10, 64)

		a.mu.Lock()
		filtered := a.configs[:0]
		for _, c := range a.configs {
			if c.ID != id {
				filtered = append(filtered, c)
			}
		}
		a.configs = filtered
		a.saveConfigsLocked()
		a.mu.Unlock()

		writeJSON(w, map[string]interface{}{"ok": true})

	default:
		httpError(w, 405, "method not allowed")
	}
}

// ============================================================
//  /api/settings
// ============================================================

func (a *App) handleSettings(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		a.mu.RLock()
		s := a.settings
		a.mu.RUnlock()
		writeJSON(w, s)

	case http.MethodPost:
		var s Settings
		if err := json.NewDecoder(r.Body).Decode(&s); err != nil {
			httpError(w, 400, "bad json")
			return
		}
		normalizeSettings(&s)

		a.mu.Lock()
		a.settings = s
		a.saveSettingsLocked()
		a.mu.Unlock()

		writeJSON(w, map[string]interface{}{"ok": true})

	default:
		httpError(w, 405, "method not allowed")
	}
}

// ============================================================
//  /api/logs
// ============================================================

func (a *App) handleLogs(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		httpError(w, 405, "method not allowed")
		return
	}

	logPath := filepath.Join(csqttDir, coreLogFile)
	data, err := os.ReadFile(logPath)
	if err != nil {
		writeJSON(w, []string{})
		return
	}

	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) > 500 {
		lines = lines[len(lines)-500:]
	}
	writeJSON(w, lines)
}

func (a *App) handleLogsClear(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpError(w, 405, "method not allowed")
		return
	}
	logPath := filepath.Join(csqttDir, coreLogFile)
	_ = os.WriteFile(logPath, []byte{}, 0644)
	writeJSON(w, map[string]interface{}{"ok": true})
}

// ============================================================
//  /api/connect
// ============================================================

func (a *App) handleConnect(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpError(w, 405, "method not allowed")
		return
	}

	var req struct {
		ConfigID int64 `json:"configId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, 400, "bad json")
		return
	}

	a.mu.RLock()
	var cfg *Config
	for i := range a.configs {
		if a.configs[i].ID == req.ConfigID {
			cfg = &a.configs[i]
			break
		}
	}
	settings := a.settings
	installerRunning := a.installerRunning
	a.mu.RUnlock()

	if cfg == nil {
		httpError(w, 404, "config not found")
		return
	}
	if installerRunning {
		httpError(w, 409, "installer already running")
		return
	}

	// M = workers, N = round(workers/9) * 3 (кратно 3), мин 3.
	workers := settings.Workers
	if workers < 1 {
		workers = 27
	}
	if workers > 127 {
		workers = 127
	}

	perHash := (workers + 8) / 9 // ceil(workers / 9)
	if perHash < 3 {
		perHash = 3
	}
	perHash = (perHash / 3) * 3
	if perHash < 3 {
		perHash = 3
	}

	// Ссылка: rawLink, иначе собираем из peer/password/hashes.
	link := cfg.RawLink
	if link == "" {
		host, port := splitHostPort(cfg.Peer)
		link = fmt.Sprintf("csqtt://connect?v=2&host=%s&peer=%s&password=%s&hashes=%s",
			host, port, cfg.Password,
			strings.ReplaceAll(cfg.Hashes, ",", "+"))
	}

	// Токен для autoVk.
	token := ""
	if settings.AuthMode == "autoVk" {
		token = a.readVkToken()
		if token == "" {
			httpError(w, 400, "authMode=autoVk, но VK-токен не задан")
			return
		}
	}

	go a.runInstaller(link, perHash, token)

	writeJSON(w, map[string]interface{}{
		"ok":      true,
		"workers": workers,
		"hashes":  perHash,
	})
}

// runInstaller скачивает и запускает установочный скрипт CSQTT.
func (a *App) runInstaller(link string, hashes int, token string) {
	a.mu.Lock()
	a.installerRunning = true
	a.mu.Unlock()

	defer func() {
		a.mu.Lock()
		a.installerRunning = false
		a.mu.Unlock()
	}()

	logPath := filepath.Join(csqttDir, coreLogFile)

	appendLog := func(format string, args ...interface{}) {
		line := fmt.Sprintf("[%s] [LaLune] %s\n",
			time.Now().Format("15:04:05"), fmt.Sprintf(format, args...))
		f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		if err == nil {
			_, _ = f.WriteString(line)
			_ = f.Close()
		}
		log.Print(line)
	}

	appendLog("Скачиваю установщик CSQTT...")

	curlCmd := exec.Command("curl", "-fsSL", "-o", installerPath, installerURL)
	curlCmd.Stdout = os.Stdout
	curlCmd.Stderr = os.Stderr
	if err := curlCmd.Run(); err != nil {
		appendLog("Ошибка скачивания установщика: %v", err)
		return
	}

	appendLog("Установщик скачан: %s", installerPath)

	// sh /tmp/csqtt-install.sh '<link>' --workers N --hashes M [--vk-token T]
	args := []string{installerPath, link,
		"--workers", strconv.Itoa(hashes),
		"--hashes", strconv.Itoa(hashes),
	}
	if token != "" {
		args = append(args, "--vk-token", token)
	}

	appendLog("Запускаю: sh %s", strings.Join(args, " "))

	cmd := exec.Command("sh", args...)
	logFile, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err == nil {
		cmd.Stdout = logFile
		cmd.Stderr = logFile
		defer logFile.Close()
	}

	if err := cmd.Start(); err != nil {
		appendLog("Ошибка запуска установщика: %v", err)
		return
	}

	go a.watchCore()

	_ = cmd.Wait()
	appendLog("Установщик завершён")
}

// watchCore отслеживает появление ядра и обновляет corePID.
func (a *App) watchCore() {
	for i := 0; i < 240; i++ { // до 2 минут
		time.Sleep(500 * time.Millisecond)
		pid := findCorePID()
		if pid > 0 {
			a.mu.Lock()
			a.corePID = pid
			a.mu.Unlock()
			return
		}
	}
}

// ============================================================
//  /api/disconnect
// ============================================================

func (a *App) handleDisconnect(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		httpError(w, 405, "method not allowed")
		return
	}

	logPath := filepath.Join(csqttDir, coreLogFile)
	appendLogFile(logPath, "[LaLune] Отключение...")

	for _, name := range []string{"csqtt", "csqtt-client", "csqtt-client-arm64"} {
		_ = exec.Command("killall", "-9", name).Run()
	}

	_ = exec.Command("ip", "link", "del", "csqtt0").Run()

	a.mu.Lock()
	a.corePID = 0
	a.mu.Unlock()

	appendLogFile(logPath, "[LaLune] Отключено")
	writeJSON(w, map[string]interface{}{"ok": true})
}

// ============================================================
//  /api/vktoken
// ============================================================

func (a *App) handleVkToken(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		tok := a.readVkToken()
		writeJSON(w, map[string]interface{}{
			"hasToken":  tok != "",
			"fetcherOk": false,
			"fetching":  false,
			"message":   "",
			"progress":  0,
		})

	case http.MethodPost:
		var req struct {
			Token string `json:"token"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			httpError(w, 400, "bad json")
			return
		}
		tok := strings.TrimSpace(req.Token)
		if tok == "" {
			httpError(w, 400, "empty token")
			return
		}

		tf := TokenFile{
			Token:   tok,
			SavedAt: time.Now().UTC().Format(time.RFC3339),
		}
		data, _ := json.MarshalIndent(tf, "", "  ")
		path := filepath.Join(csqttDir, tokenFile)
		if err := os.WriteFile(path, data, 0600); err != nil {
			httpError(w, 500, "save failed")
			return
		}

		writeJSON(w, map[string]interface{}{"ok": true})

	case http.MethodDelete:
		_ = os.Remove(filepath.Join(csqttDir, tokenFile))
		writeJSON(w, map[string]interface{}{"ok": true})

	default:
		httpError(w, 405, "method not allowed")
	}
}

// ============================================================
//  /api/updates
// ============================================================

func (a *App) handleUpdates(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, map[string]interface{}{
			"update":  false,
			"version": "0.5.0",
		})

	case http.MethodPost:
		writeJSON(w, map[string]interface{}{"ok": true})

	default:
		httpError(w, 405, "method not allowed")
	}
}

// ============================================================
//  Хранилище
// ============================================================

func (a *App) loadConfigs() {
	path := filepath.Join(csqttDir, configsFile)
	data, err := os.ReadFile(path)
	if err != nil {
		a.configs = []Config{}
		return
	}
	var cfgs []Config
	if err := json.Unmarshal(data, &cfgs); err != nil {
		a.configs = []Config{}
		return
	}
	a.configs = cfgs
}

func (a *App) saveConfigsLocked() {
	data, _ := json.MarshalIndent(a.configs, "", "  ")
	_ = os.WriteFile(filepath.Join(csqttDir, configsFile), data, 0644)
}

func (a *App) loadSettings() {
	path := filepath.Join(csqttDir, settingsFile)
	data, err := os.ReadFile(path)
	if err != nil {
		a.settings = defaultSettings()
		return
	}
	var s Settings
	if err := json.Unmarshal(data, &s); err != nil {
		a.settings = defaultSettings()
		return
	}
	normalizeSettings(&s)
	a.settings = s
}

func (a *App) saveSettingsLocked() {
	data, _ := json.MarshalIndent(a.settings, "", "  ")
	_ = os.WriteFile(filepath.Join(csqttDir, settingsFile), data, 0644)
}

func (a *App) readVkToken() string {
	path := filepath.Join(csqttDir, tokenFile)
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var tf TokenFile
	if err := json.Unmarshal(data, &tf); err != nil {
		return ""
	}
	return strings.TrimSpace(tf.Token)
}

func defaultSettings() Settings {
	return Settings{
		AuthMode:      "manual",
		Workers:       27,
		VkAuthMode:    "vkcalls",
		Obfs:          "video",
		Fingerprint:   "firefox",
		ClientIds:     "8202606,6287487",
		CaptchaMode:   "auto",
		TurnTransport: "udp",
	}
}

func normalizeSettings(s *Settings) {
	if s.AuthMode != "autoVk" {
		s.AuthMode = "manual"
	}
	if s.Workers < 1 {
		s.Workers = 27
	}
	if s.Workers > 127 {
		s.Workers = 127
	}
	if s.Obfs == "" {
		s.Obfs = "video"
	}
	if s.Fingerprint == "" {
		s.Fingerprint = "firefox"
	}
	if s.ClientIds == "" {
		s.ClientIds = "8202606,6287487"
	}
	if s.CaptchaMode == "" {
		s.CaptchaMode = "auto"
	}
	if s.TurnTransport == "" {
		s.TurnTransport = "udp"
	}
}

// ============================================================
//  Парсинг csqtt:// ссылки
// ============================================================

func parseCsqttLink(link string) Config {
	cfg := Config{Protocol: "CSQTT", Name: "Config", RawLink: link}
	link = strings.TrimSpace(link)

	if !strings.HasPrefix(strings.ToLower(link), "csqtt://") {
		cfg.Peer = link
		return cfg
	}

	rest := link[len("csqtt://"):]

	if strings.HasPrefix(rest, "connect?") {
		query := rest[len("connect?"):]
		params := parseQuery(query)

		host := params["host"]
		port := params["peer"]
		password := params["password"]
		hashes := strings.ReplaceAll(params["hashes"], "+", ",")

		cfg.Peer = host + ":" + port
		cfg.Password = password
		cfg.Hashes = hashes
		cfg.Name = cfg.Peer
		return cfg
	}

	at := strings.Index(rest, "@")
	if at < 0 {
		cfg.Peer = link
		return cfg
	}
	userinfo := rest[:at]
	hostport := rest[at+1:]

	colon := strings.Index(userinfo, ":")
	if colon < 0 {
		cfg.Peer = hostport
		return cfg
	}
	cfg.Password = userinfo[colon+1:]
	if !strings.Contains(hostport, ":") {
		hostport += ":46000"
	}
	cfg.Peer = hostport
	cfg.Name = cfg.Peer
	return cfg
}

func parseQuery(q string) map[string]string {
	out := map[string]string{}
	for _, kv := range strings.Split(q, "&") {
		if kv == "" {
			continue
		}
		parts := strings.SplitN(kv, "=", 2)
		k := parts[0]
		v := ""
		if len(parts) > 1 {
			v = parts[1]
		}
		out[k] = v
	}
	return out
}

func splitHostPort(s string) (string, string) {
	i := strings.LastIndex(s, ":")
	if i < 0 {
		return s, "46000"
	}
	return s[:i], s[i+1:]
}

// ============================================================
//  Утилиты
// ============================================================

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(v)
}

func httpError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_, _ = io.WriteString(w, fmt.Sprintf(`{"error":%q}`, msg))
}

func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	proc, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return proc.Signal(syscall.Signal(0)) == nil
}

func findCorePID() int {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return 0
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		cmdline, err := os.ReadFile(filepath.Join("/proc", e.Name(), "cmdline"))
		if err != nil {
			continue
		}
		s := string(cmdline)
		if strings.Contains(s, "csqtt") && !strings.Contains(s, "install") {
			return pid
		}
	}
	return 0
}

func appendLogFile(path, line string) {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString(fmt.Sprintf("[%s] %s\n",
		time.Now().Format("15:04:05"), line))
}
