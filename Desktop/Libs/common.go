// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

package libs

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	_ "modernc.org/sqlite"
)

const (
	LATEST_URL          = "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST"
	CORE_URL_TEMPLATE   = "https://github.com/Endlad2/csqtt-core/releases/download/%s/%s"
	WINTUN_URL          = "https://www.wintun.net/builds/wintun-0.14.1.zip"
	WINTUN_FALLBACK_URL = "http://31.77.148.203:8855/?url=https://www.wintun.net/builds/wintun-0.14.1.zip"
	PROXY_URL           = "http://31.77.148.203:8855/?url="
	USER_AGENT          = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
	HTTP_TIMEOUT        = 30 * time.Second

	LaLuneVersion = "0.5.0"

	DefaultWorkers        = 9
	MinWorkers            = 1
	MaxWorkers            = 127
	DefaultAutoApiWorkers = 9
	MinAutoApiWorkers     = 9
	MaxAutoApiWorkers     = 27
)

type Config struct {
	ID       int64  `json:"id"`
	Protocol string `json:"protocol"`
	Peer     string `json:"peer"`
	Password string `json:"password"`
	Hashes   string `json:"hashes"`
	Name     string `json:"name"`
	RawLink  string `json:"rawLink"`
	// Token извлекается из csqtt://...&token=... при добавлении конфига
	// и сохраняется в token.json. В БД не хранится (не нужно).
	Token string `json:"-"`
}

type Settings struct {
	Peer                    string `json:"peer"`
	VkHashes                string `json:"vkHashes"`
	VkJsToken               string `json:"vkJsToken"` // legacy
	TurnHost                string `json:"turnHost"`
	TurnPort                string `json:"turnPort"`
	TurnTransport           string `json:"turnTransport"`
	Workers                 int    `json:"workers"`
	AutoApiWorkers          int    `json:"autoApiWorkers"`
	Obfs                    string `json:"obfs"`
	Fingerprint             string `json:"fingerprint"`
	ClientIds               string `json:"clientIds"`
	VkAuthMode              string `json:"vkAuthMode"`
	CaptchaMode             string `json:"captchaMode"`
	DeviceId                string `json:"deviceId"`
	AutoConnect             bool   `json:"autoConnect"`
	AuthMode                string `json:"authMode"`
	AllowHashRedistribution bool   `json:"allowHashRedistribution"`
	ValidateVkHashes        bool   `json:"validateVkHashes"`

	// Экспериментальные функции.
	EnableSmartTunnel bool `json:"enableSmartTunnel"`
}

type AppCore struct {
	ctx             context.Context
	db              *sql.DB
	settings        Settings
	settingsFile    string
	latestFile      string
	corePath        string
	wintunPath      string
	appDir          string
	isConnected     bool
	mu              sync.Mutex
	logs            []string
	logCallback     func(string)
	statusCallback  func(bool)
	configsCallback func(string)
	updateCallback  func(string)
	isDownloading   bool

	selectedConfig *Config
	selMu          sync.RWMutex

	coreDownloading   bool
	coreDownloadingMu sync.RWMutex
	coreDownloadingCb func(bool)

	activeCallIds []string
	activeCallMux sync.Mutex

	smartTunnel *SmartTunnel
}

func NewAppCore() *AppCore { return &AppCore{logs: []string{}} }

func (a *AppCore) Startup(ctx context.Context) {
	a.ctx = ctx
	a.appDir = a.GetAppDataDir()

	if err := os.MkdirAll(a.appDir, 0755); err != nil {
		a.AddLog(fmt.Sprintf("[ERROR] Не удалось создать папку %s: %v", a.appDir, err))
	}

	a.settingsFile = filepath.Join(a.appDir, "settings.json")
	a.latestFile = filepath.Join(a.appDir, "LATEST")
	a.corePath = filepath.Join(a.appDir, a.GetCoreFilename())
	a.wintunPath = filepath.Join(a.appDir, "wintun.dll")

	a.AddLog(fmt.Sprintf("[INFO] Папка приложения: %s", a.appDir))

	a.InitDB()
	a.LoadSettings()

	// SmartTunnel — запускаем, если включён в настройках.
	a.smartTunnel = NewSmartTunnel(a)
	if a.settings.EnableSmartTunnel {
		if err := a.smartTunnel.Start(); err != nil {
			a.AddLog(fmt.Sprintf("[SMART-TUNNEL] Ошибка запуска: %v", err))
		}
	}
}

func (a *AppCore) GetAppDataDir() string {
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

func (a *AppCore) GetCoreFilename() string {
	switch runtime.GOOS {
	case "windows":
		return "client-windows-x86_64.exe"
	case "darwin":
		return "client-macos-x86_64"
	default:
		return "client-linux-x86_64"
	}
}

func (a *AppCore) InitDB() {
	dbPath := filepath.Join(a.appDir, "configs.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		a.AddLog(fmt.Sprintf("[DB] Ошибка открытия: %v", err))
		return
	}
	if err := db.Ping(); err != nil {
		a.AddLog(fmt.Sprintf("[DB] Ошибка ping: %v", err))
		return
	}

	createTableSQL := `CREATE TABLE IF NOT EXISTS configs (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		protocol TEXT NOT NULL DEFAULT 'CSQTT',
		peer TEXT NOT NULL DEFAULT '',
		password TEXT NOT NULL DEFAULT '',
		hashes TEXT NOT NULL DEFAULT '',
		name TEXT DEFAULT '',
		created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
		updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
	)`
	if _, err := db.Exec(createTableSQL); err != nil {
		a.AddLog(fmt.Sprintf("[DB] Ошибка создания таблицы: %v", err))
		return
	}

	a.db = db
	a.AddLog("[DB] БД инициализирована")
}

func (a *AppCore) LoadSettings() {
	data, err := os.ReadFile(a.settingsFile)
	if err != nil {
		a.settings = Settings{
			Workers:           DefaultWorkers,
			AutoApiWorkers:    DefaultAutoApiWorkers,
			Obfs:              "audio",
			Fingerprint:       "chrome",
			ClientIds:         "8202606,6287487",
			VkAuthMode:        "vkcalls",
			CaptchaMode:       "auto",
			TurnTransport:     "udp",
			DeviceId:          uuid.New().String(),
			AuthMode:          "manual",
			EnableSmartTunnel: false,
		}
		a.SaveSettingsFile()
		return
	}

	if err := json.Unmarshal(data, &a.settings); err != nil {
		a.AddLog(fmt.Sprintf("[SETTINGS] Ошибка парсинга: %v", err))
		return
	}

	if a.settings.DeviceId == "" {
		a.settings.DeviceId = uuid.New().String()
		a.SaveSettingsFile()
	}
	if a.settings.AuthMode == "" {
		a.settings.AuthMode = "manual"
	}
	if a.settings.TurnTransport == "" {
		a.settings.TurnTransport = "udp"
	}

	if a.settings.Workers <= 0 {
		a.settings.Workers = DefaultWorkers
	}
	if a.settings.Workers < MinWorkers {
		a.settings.Workers = MinWorkers
	}
	if a.settings.Workers > MaxWorkers {
		a.settings.Workers = MaxWorkers
	}

	if a.settings.AutoApiWorkers <= 0 {
		a.settings.AutoApiWorkers = DefaultAutoApiWorkers
	}
	if a.settings.AutoApiWorkers < MinAutoApiWorkers {
		a.settings.AutoApiWorkers = MinAutoApiWorkers
	}
	if a.settings.AutoApiWorkers > MaxAutoApiWorkers {
		a.settings.AutoApiWorkers = MaxAutoApiWorkers
	}

	a.AddLog("[SETTINGS] Настройки загружены")
}

func (a *AppCore) SaveSettingsFile() {
	data, _ := json.MarshalIndent(a.settings, "", "  ")
	if err := os.WriteFile(a.settingsFile, data, 0644); err != nil {
		a.AddLog(fmt.Sprintf("[SETTINGS] Ошибка сохранения: %v", err))
	}
}

func (a *AppCore) LoadConfigs() {
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
		if err := rows.Scan(&c.ID, &c.Protocol, &c.Peer, &c.Password, &c.Hashes, &c.Name); err != nil {
			continue
		}
		configs = append(configs, c)
	}

	data, _ := json.Marshal(configs)
	if a.configsCallback != nil {
		a.configsCallback(string(data))
	}
}

// ============ API для JS ============

func (a *AppCore) GetConfigsJson() string {
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
		if err := rows.Scan(&c.ID, &c.Protocol, &c.Peer, &c.Password, &c.Hashes, &c.Name); err != nil {
			continue
		}
		configs = append(configs, c)
	}
	data, _ := json.Marshal(configs)
	return string(data)
}

func (a *AppCore) GetSettingsJson() string {
	data, _ := json.Marshal(a.settings)
	return string(data)
}

func (a *AppCore) GetLogsJson() string {
	a.mu.Lock()
	logs := append([]string{}, a.logs...)
	a.mu.Unlock()
	data, _ := json.Marshal(logs)
	return string(data)
}

// SaveConfig — сохраняет конфиг из ссылки.
//
// Если в ссылке есть &token=..., токен извлекается и сразу пишется
// в token.json (см. tokenfile.go). Это тот же формат, что использует
// LaLuneTokenFetcher, поэтому автоВК-режим подхватит его без лишних действий.
func (a *AppCore) SaveConfig(link string) bool {
	config := ParseCsqttLink(link)
	config.RawLink = link

	result, err := a.db.Exec(
		"INSERT INTO configs (protocol, peer, password, hashes, name) VALUES (?, ?, ?, ?, ?)",
		config.Protocol, config.Peer, config.Password, config.Hashes, config.Name,
	)
	if err != nil {
		a.AddLog(fmt.Sprintf("[API] Ошибка сохранения конфига: %v", err))
		return false
	}
	id, _ := result.LastInsertId()
	a.AddLog(fmt.Sprintf("[API] Конфиг сохранён с ID: %d", id))

	// Если из ссылки пришёл токен — сразу пишем в token.json.
	if strings.TrimSpace(config.Token) != "" {
		if path, err := a.SaveTokenToFile(config.Token); err != nil {
			a.AddLog(fmt.Sprintf("[VK] Не удалось сохранить токен из ссылки: %v", err))
		} else {
			a.AddLog(fmt.Sprintf("[VK] Токен из ссылки сохранён: %s", path))
		}
	}

	a.LoadConfigs()
	return true
}

func (a *AppCore) DeleteConfig(id int64) bool {
	if _, err := a.db.Exec("DELETE FROM configs WHERE id = ?", id); err != nil {
		return false
	}
	a.LoadConfigs()
	return true
}

func (a *AppCore) SaveSettings(settingsJson string) bool {
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
	if newSettings.VkJsToken == "" {
		newSettings.VkJsToken = a.settings.VkJsToken
	}
	if newSettings.AuthMode == "" {
		newSettings.AuthMode = "manual"
	}
	if newSettings.TurnTransport == "" {
		newSettings.TurnTransport = "udp"
	}

	if newSettings.Workers < MinWorkers {
		newSettings.Workers = MinWorkers
	}
	if newSettings.Workers > MaxWorkers {
		newSettings.Workers = MaxWorkers
	}

	if newSettings.AutoApiWorkers < MinAutoApiWorkers {
		newSettings.AutoApiWorkers = MinAutoApiWorkers
	}
	if newSettings.AutoApiWorkers > MaxAutoApiWorkers {
		newSettings.AutoApiWorkers = MaxAutoApiWorkers
	}

	oldSmartTunnel := a.settings.EnableSmartTunnel

	a.mu.Lock()
	a.settings = newSettings
	data, _ := json.MarshalIndent(a.settings, "", "  ")
	_ = os.WriteFile(a.settingsFile, data, 0644)
	a.mu.Unlock()

	// Реагируем на изменение флага SmartTunnel.
	if a.smartTunnel != nil && oldSmartTunnel != newSettings.EnableSmartTunnel {
		if newSettings.EnableSmartTunnel {
			if err := a.smartTunnel.Start(); err != nil {
				a.AddLog(fmt.Sprintf("[SMART-TUNNEL] Ошибка запуска: %v", err))
			}
		} else {
			a.smartTunnel.Stop()
		}
	}

	a.AddLog("[API] Настройки сохранены")
	return true
}

func (a *AppCore) ClearLogs() bool {
	a.mu.Lock()
	a.logs = []string{}
	a.mu.Unlock()
	a.AddLog("=== Логи очищены ===")
	return true
}

func (a *AppCore) SetLogCallback(cb func(string))     { a.logCallback = cb }
func (a *AppCore) SetStatusCallback(cb func(bool))    { a.statusCallback = cb }
func (a *AppCore) SetConfigsCallback(cb func(string)) { a.configsCallback = cb }
func (a *AppCore) SetUpdateCallback(cb func(string))  { a.updateCallback = cb }

func (a *AppCore) SetCoreDownloadingCallback(cb func(bool)) {
	a.coreDownloadingMu.Lock()
	a.coreDownloadingCb = cb
	a.coreDownloadingMu.Unlock()
}

func (a *AppCore) NotifyCoreDownloading(downloading bool) {
	a.coreDownloadingMu.Lock()
	a.coreDownloading = downloading
	cb := a.coreDownloadingCb
	a.coreDownloadingMu.Unlock()
	if cb != nil {
		cb(downloading)
	}
}

func (a *AppCore) IsCoreDownloading() bool {
	a.coreDownloadingMu.RLock()
	defer a.coreDownloadingMu.RUnlock()
	return a.coreDownloading
}

// ============ Глобально выбранный конфиг ============

func (a *AppCore) SetSelectedConfig(config *Config) {
	a.selMu.Lock()
	a.selectedConfig = config
	a.selMu.Unlock()
}

func (a *AppCore) GetSelectedConfig() *Config {
	a.selMu.RLock()
	defer a.selMu.RUnlock()
	return a.selectedConfig
}

func (a *AppCore) GetSelectedConfigJson() string {
	c := a.GetSelectedConfig()
	if c == nil {
		return "{}"
	}
	data, _ := json.Marshal(c)
	return string(data)
}

func (a *AppCore) SetSelectedConfigJson(jsonStr string) bool {
	var c Config
	if err := json.Unmarshal([]byte(jsonStr), &c); err != nil {
		return false
	}
	a.SetSelectedConfig(&c)
	return true
}

// ============ Внутренние методы ============

func (a *AppCore) AddLog(message string) {
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

func (a *AppCore) IsConnected() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.isConnected
}

func (a *AppCore) SetConnected(connected bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.isConnected = connected
	if a.statusCallback != nil {
		a.statusCallback(connected)
	}
}

func (a *AppCore) GetDB() *sql.DB        { return a.db }
func (a *AppCore) GetSettings() Settings { return a.settings }
func (a *AppCore) GetAppDir() string     { return a.appDir }
func (a *AppCore) GetCorePath() string   { return a.corePath }
func (a *AppCore) GetLatestFile() string { return a.latestFile }
func (a *AppCore) GetWintunPath() string { return a.wintunPath }

// ParseCsqttLink — разбирает csqtt:// ссылку.
//
// Поддерживает два формата:
//   1. csqtt://connect?v=2&host=...&peer=...&password=...&hashes=...&token=...
//   2. csqtt://user:password@host:port
//
// Если в query есть &token=..., он попадает в Config.Token и используется
// в SaveConfig для записи в token.json.
func ParseCsqttLink(link string) Config {
	config := Config{Protocol: "CSQTT", Name: "Config"}
	link = strings.TrimSpace(link)
	if !strings.HasPrefix(strings.ToLower(link), "csqtt://") {
		config.Peer = link
		config.RawLink = link
		return config
	}

	parsed, err := url.Parse(link)
	if err != nil {
		config.Peer = link
		config.RawLink = link
		return config
	}
	params := parsed.Query()

	if strings.ToLower(parsed.Hostname()) == "connect" {
		if params.Get("v") != "2" {
			config.Peer = link
			config.RawLink = link
			return config
		}
		host := params.Get("host")
		port := params.Get("peer")
		password := params.Get("password")
		if host == "" || port == "" || password == "" {
			config.Peer = link
			config.RawLink = link
			return config
		}
		config.Peer = fmt.Sprintf("%s:%s", host, port)
		config.Password = password
		if hashes := params.Get("hashes"); hashes != "" {
			var clean []string
			for _, p := range strings.Split(hashes, "+") {
				if p != "" {
					clean = append(clean, p)
				}
			}
			config.Hashes = strings.Join(clean, ",")
		}
		// ВК-токен прямо в ссылке.
		if tok := params.Get("token"); tok != "" {
			config.Token = tok
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
			config.RawLink = link
			return config
		}
		config.Peer = fmt.Sprintf("%s:%s", host, port)
		config.Password = password
		config.Name = config.Peer
	}
	config.RawLink = link
	return config
}

func (a *AppCore) GetConfigByID(id int64) *Config {
	row := a.db.QueryRow("SELECT id, protocol, peer, password, hashes, name FROM configs WHERE id = ?", id)
	var c Config
	if err := row.Scan(&c.ID, &c.Protocol, &c.Peer, &c.Password, &c.Hashes, &c.Name); err != nil {
		return nil
	}
	return &c
}
