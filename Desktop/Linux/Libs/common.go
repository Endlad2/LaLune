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
	LATEST_URL           = "https://raw.githubusercontent.com/Endlad2/csqtt-core/refs/heads/main/LATEST"
	CORE_URL_TEMPLATE    = "https://github.com/Endlad2/csqtt-core/releases/download/%s/%s"
	WINTUN_URL           = "https://www.wintun.net/builds/wintun-0.14.1.zip"
	WINTUN_FALLBACK_URL  = "http://31.77.148.203:8855/?url=https://www.wintun.net/builds/wintun-0.14.1.zip"
	PROXY_URL            = "http://31.77.148.203:8855/?url="
	USER_AGENT           = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
	HTTP_TIMEOUT         = 30 * time.Second
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

// AppCore - общая логика приложения (не зависит от платформы)
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
}

func NewAppCore() *AppCore {
	return &AppCore{
		logs: []string{},
	}
}

func (a *AppCore) Startup(ctx context.Context) {
	a.ctx = ctx
	a.appDir = a.GetAppDataDir()

	// Создаем папку если её нет
	if err := os.MkdirAll(a.appDir, 0755); err != nil {
		a.AddLog(fmt.Sprintf("[ERROR] Не удалось создать папку %s: %v", a.appDir, err))
	}

	a.settingsFile = filepath.Join(a.appDir, "settings.json")
	a.latestFile = filepath.Join(a.appDir, "LATEST")
	a.corePath = filepath.Join(a.appDir, a.GetCoreFilename())
	a.wintunPath = filepath.Join(a.appDir, "wintun.dll")

	a.AddLog(fmt.Sprintf("[INFO] Папка приложения: %s", a.appDir))
	a.AddLog(fmt.Sprintf("[INFO] Путь к БД: %s", filepath.Join(a.appDir, "configs.db")))

	a.InitDB()
	a.LoadSettings()
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
	a.AddLog(fmt.Sprintf("[DB] Инициализация БД: %s", dbPath))
	
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		a.AddLog(fmt.Sprintf("[DB] Ошибка открытия: %v", err))
		return
	}

	// Проверяем подключение
	if err := db.Ping(); err != nil {
		a.AddLog(fmt.Sprintf("[DB] Ошибка ping: %v", err))
		return
	}

	// Создаем таблицу
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
	
	_, err = db.Exec(createTableSQL)
	if err != nil {
		a.AddLog(fmt.Sprintf("[DB] Ошибка создания таблицы: %v", err))
		return
	}

	// Проверяем, есть ли данные
	var count int
	err = db.QueryRow("SELECT COUNT(*) FROM configs").Scan(&count)
	if err != nil {
		a.AddLog(fmt.Sprintf("[DB] Ошибка подсчета записей: %v", err))
	} else {
		a.AddLog(fmt.Sprintf("[DB] Найдено %d конфигов", count))
	}

	a.db = db
	a.AddLog("[DB] БД инициализирована успешно")
}

func (a *AppCore) LoadSettings() {
	data, err := os.ReadFile(a.settingsFile)
	if err != nil {
		a.AddLog("[SETTINGS] Файл настроек не найден, создаю стандартные")
		a.settings = Settings{
			WorkersPerHash: 9,
			Obfs:           "video",
			Fingerprint:    "firefox",
			ClientIds:      "8202606,6287487",
			VkAuthMode:     "vkcalls",
			CaptchaMode:    "auto",
			DeviceId:       uuid.New().String(),
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
		a.AddLog("[CONFIGS] БД не инициализирована")
		return
	}

	a.AddLog("[CONFIGS] Загрузка конфигов из БД...")
	
	rows, err := a.db.Query("SELECT id, protocol, peer, password, hashes, name FROM configs ORDER BY id DESC")
	if err != nil {
		a.AddLog(fmt.Sprintf("[CONFIGS] Ошибка запроса: %v", err))
		return
	}
	defer rows.Close()

	var configs []Config
	for rows.Next() {
		var c Config
		if err := rows.Scan(&c.ID, &c.Protocol, &c.Peer, &c.Password, &c.Hashes, &c.Name); err != nil {
			a.AddLog(fmt.Sprintf("[CONFIGS] Ошибка сканирования: %v", err))
			continue
		}
		configs = append(configs, c)
	}

	a.AddLog(fmt.Sprintf("[CONFIGS] Загружено %d конфигов", len(configs)))

	data, _ := json.Marshal(configs)
	if a.configsCallback != nil {
		a.configsCallback(string(data))
	}
}

// ============ API для JS ============

func (a *AppCore) GetConfigsJson() string {
	if a.db == nil {
		a.AddLog("[API] GetConfigsJson: БД не инициализирована")
		return "[]"
	}

	rows, err := a.db.Query("SELECT id, protocol, peer, password, hashes, name FROM configs ORDER BY id DESC")
	if err != nil {
		a.AddLog(fmt.Sprintf("[API] GetConfigsJson ошибка: %v", err))
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

func (a *AppCore) SaveConfig(link string) bool {
	a.AddLog(fmt.Sprintf("[API] Сохранение конфига: %s", link))
	config := ParseCsqttLink(link)

	result, err := a.db.Exec(
		"INSERT INTO configs (protocol, peer, password, hashes, name) VALUES (?, ?, ?, ?, ?)",
		config.Protocol, config.Peer, config.Password, config.Hashes, config.Name,
	)
	if err != nil {
		a.AddLog(fmt.Sprintf("[API] Ошибка сохранения: %v", err))
		return false
	}

	id, _ := result.LastInsertId()
	a.AddLog(fmt.Sprintf("[API] Конфиг сохранен с ID: %d", id))
	a.LoadConfigs()
	return true
}

func (a *AppCore) DeleteConfig(id int64) bool {
	a.AddLog(fmt.Sprintf("[API] Удаление конфига ID: %d", id))
	
	_, err := a.db.Exec("DELETE FROM configs WHERE id = ?", id)
	if err != nil {
		a.AddLog(fmt.Sprintf("[API] Ошибка удаления: %v", err))
		return false
	}
	
	a.AddLog(fmt.Sprintf("[API] Конфиг %d удален", id))
	a.LoadConfigs()
	return true
}

func (a *AppCore) SaveSettings(settingsJson string) bool {
	a.AddLog("[API] Сохранение настроек")
	
	var newSettings Settings
	if err := json.Unmarshal([]byte(settingsJson), &newSettings); err != nil {
		a.AddLog(fmt.Sprintf("[API] Ошибка парсинга настроек: %v", err))
		return false
	}

	if newSettings.DeviceId == "" {
		newSettings.DeviceId = a.settings.DeviceId
	}
	if newSettings.DeviceId == "" {
		newSettings.DeviceId = uuid.New().String()
	}

	a.settings = newSettings
	a.SaveSettingsFile()
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

func (a *AppCore) SetLogCallback(callback func(string)) {
	a.logCallback = callback
}

func (a *AppCore) SetStatusCallback(callback func(bool)) {
	a.statusCallback = callback
}

func (a *AppCore) SetConfigsCallback(callback func(string)) {
	a.configsCallback = callback
}

func (a *AppCore) SetUpdateCallback(callback func(string)) {
	a.updateCallback = callback
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

func (a *AppCore) GetDB() *sql.DB {
	return a.db
}

func (a *AppCore) GetSettings() Settings {
	return a.settings
}

func (a *AppCore) GetAppDir() string {
	return a.appDir
}

func (a *AppCore) GetCorePath() string {
	return a.corePath
}

func (a *AppCore) GetLatestFile() string {
	return a.latestFile
}

func (a *AppCore) GetWintunPath() string {
	return a.wintunPath
}

func ParseCsqttLink(link string) Config {
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

func (a *AppCore) GetConfigByID(id int64) *Config {
	row := a.db.QueryRow("SELECT id, protocol, peer, password, hashes, name FROM configs WHERE id = ?", id)
	var c Config
	if err := row.Scan(&c.ID, &c.Protocol, &c.Peer, &c.Password, &c.Hashes, &c.Name); err != nil {
		return nil
	}
	return &c
}
