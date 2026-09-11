package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// Settings — единый формат с Desktop/Android.
// Файл: /etc/lalune/settings.json
type Settings struct {
	Peer           string `json:"peer"`
	Password       string `json:"password"`
	VkHashes       string `json:"vkHashes"`
	WorkersPerHash int    `json:"workersPerHash"`
	Obfs           string `json:"obfs"`
	Fingerprint    string `json:"fingerprint"`
	ClientIds      string `json:"clientIds"`
	VkAuthMode     string `json:"vkAuthMode"`
	CaptchaMode    string `json:"captchaMode"`
	DeviceId       string `json:"deviceId"`
	AutoConnect    bool   `json:"autoConnect"`
	TunName        string `json:"tunName"`
}

// Config — сохранённый конфиг подключения.
// Файл: /etc/lalune/configs.json (массив таких объектов)
type Config struct {
	ID       int64  `json:"id"`
	Protocol string `json:"protocol"`
	Peer     string `json:"peer"`
	Password string `json:"password"`
	Hashes   string `json:"hashes"`
	Name     string `json:"name"`
}

// ConfigStore — атомарное хранилище настроек и списка конфигов.
type ConfigStore struct {
	mu       sync.Mutex
	settings Settings
	configs  []Config
}

// NewConfigStore создаёт хранилище, читает файлы и гарантирует,
// что все обязательные поля (deviceId, defaults) заполнены.
func NewConfigStore() (*ConfigStore, error) {
	if err := os.MkdirAll(ConfigDir, 0755); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", ConfigDir, err)
	}
	if err := os.MkdirAll(CoreDir, 0755); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", CoreDir, err)
	}
	if err := os.MkdirAll(RunDir, 0755); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", RunDir, err)
	}

	cs := &ConfigStore{}
	cs.settings = defaultSettings()

	if err := cs.loadSettings(); err != nil {
		return nil, err
	}
	if err := cs.loadConfigs(); err != nil {
		return nil, err
	}
	return cs, nil
}

func defaultSettings() Settings {
	return Settings{
		WorkersPerHash: 9,
		Obfs:           "video",
		Fingerprint:    "firefox",
		ClientIds:      "8202606,6287487",
		VkAuthMode:     "vkcalls",
		CaptchaMode:    "auto",
		DeviceId:       generateDeviceID(),
		TunName:        "csqtt0",
	}
}

// generateDeviceID — 32 hex-символа без дефисов, как на Desktop/Android.
func generateDeviceID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		// fallback, чтобы уж точно не падать
		return "00000000000000000000000000000000"
	}
	return hex.EncodeToString(b)
}

func (cs *ConfigStore) loadSettings() error {
	data, err := os.ReadFile(SettingsFile)
	if err != nil {
		// Файла нет — создаём дефолтный с deviceId.
		cs.settings = defaultSettings()
		return cs.saveSettingsLocked()
	}

	var s Settings
	if err := json.Unmarshal(data, &s); err != nil {
		// Повреждён — пересоздаём, чтобы не падать.
		cs.settings = defaultSettings()
		return cs.saveSettingsLocked()
	}

	// Заполняем пропущенные поля дефолтами, не затирая существующие.
	if s.WorkersPerHash == 0 {
		s.WorkersPerHash = 9
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
	if s.VkAuthMode == "" {
		s.VkAuthMode = "vkcalls"
	}
	if s.CaptchaMode == "" {
		s.CaptchaMode = "auto"
	}
	if s.TunName == "" {
		s.TunName = "csqtt0"
	}
	if strings.TrimSpace(s.DeviceId) == "" {
		s.DeviceId = generateDeviceID()
	}

	cs.settings = s
	return cs.saveSettingsLocked()
}

func (cs *ConfigStore) loadConfigs() error {
	data, err := os.ReadFile(ConfigsFile)
	if err != nil {
		cs.configs = []Config{}
		return cs.saveConfigsLocked()
	}
	var arr []Config
	if err := json.Unmarshal(data, &arr); err != nil {
		cs.configs = []Config{}
		return cs.saveConfigsLocked()
	}
	cs.configs = arr
	return nil
}

// ============ Public API ============

func (cs *ConfigStore) GetSettings() Settings {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	return cs.settings
}

func (cs *ConfigStore) SetSettings(s Settings) error {
	cs.mu.Lock()
	defer cs.mu.Unlock()

	// deviceId никогда не затираем пустым — только явной перегенерацией.
	if strings.TrimSpace(s.DeviceId) == "" {
		s.DeviceId = cs.settings.DeviceId
	}
	if s.TunName == "" {
		s.TunName = "csqtt0"
	}
	cs.settings = s
	return cs.saveSettingsLocked()
}

func (cs *ConfigStore) RegenerateDeviceID() string {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	cs.settings.DeviceId = generateDeviceID()
	_ = cs.saveSettingsLocked()
	return cs.settings.DeviceId
}

func (cs *ConfigStore) GetConfigs() []Config {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	out := make([]Config, len(cs.configs))
	copy(out, cs.configs)
	return out
}

func (cs *ConfigStore) AddConfig(c Config) error {
	cs.mu.Lock()
	defer cs.mu.Unlock()

	if c.Protocol == "" {
		c.Protocol = "CSQTT"
	}
	if c.Name == "" {
		c.Name = c.Peer
	}
	var maxID int64
	for _, x := range cs.configs {
		if x.ID > maxID {
			maxID = x.ID
		}
	}
	c.ID = maxID + 1
	cs.configs = append(cs.configs, c)
	return cs.saveConfigsLocked()
}

func (cs *ConfigStore) DeleteConfig(id int64) error {
	cs.mu.Lock()
	defer cs.mu.Unlock()

	out := cs.configs[:0]
	for _, c := range cs.configs {
		if c.ID != id {
			out = append(out, c)
		}
	}
	cs.configs = out
	return cs.saveConfigsLocked()
}

func (cs *ConfigStore) GetConfigByID(id int64) *Config {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	for i := range cs.configs {
		if cs.configs[i].ID == id {
			c := cs.configs[i]
			return &c
		}
	}
	return nil
}

// ============ Internal ============

func (cs *ConfigStore) saveSettingsLocked() error {
	data, err := json.MarshalIndent(cs.settings, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(SettingsFile, data, 0644)
}

func (cs *ConfigStore) saveConfigsLocked() error {
	data, err := json.MarshalIndent(cs.configs, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(ConfigsFile, data, 0644)
}

// atomicWrite пишет через временный файл, чтобы не оставить «половину» при сбое.
func atomicWrite(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ParseCsqttLink — парсер ссылок csqtt://connect?... и csqtt://user:pass@host:port
// Логика один-в-один с Desktop/Android, чтобы конфиги были совместимы.
func ParseCsqttLink(link string) Config {
	c := Config{Protocol: "CSQTT", Name: "Config"}
	link = strings.TrimSpace(link)

	if !strings.HasPrefix(strings.ToLower(link), "csqtt://") {
		c.Peer = link
		return c
	}

	rest := link[len("csqtt://"):]

	if strings.HasPrefix(rest, "connect?") {
		query := rest[len("connect?"):]
		params := parseQuery(query)
		if params["v"] != "2" {
			c.Peer = link
			return c
		}
		host := params["host"]
		port := params["peer"]
		pwd := params["password"]
		if host == "" || port == "" || pwd == "" {
			c.Peer = link
			return c
		}
		c.Peer = host + ":" + port
		c.Password = pwd

		if h := params["hashes"]; h != "" {
			parts := strings.Split(h, "+")
			var clean []string
			for _, p := range parts {
				if p != "" {
					clean = append(clean, p)
				}
			}
			c.Hashes = strings.Join(clean, ",")
		}
		c.Name = c.Peer
		return c
	}

	// csqtt://user:pass@host:port
	at := strings.Index(rest, "@")
	if at < 0 {
		c.Peer = link
		return c
	}
	userinfo := rest[:at]
	hostport := rest[at+1:]

	colon := strings.Index(userinfo, ":")
	if colon < 0 {
		c.Peer = link
		return c
	}
	pwd := userinfo[colon+1:]

	if !strings.Contains(hostport, ":") {
		hostport += ":46000"
	}
	c.Peer = hostport
	c.Password = pwd
	c.Name = hostport
	return c
}

func parseQuery(q string) map[string]string {
	out := map[string]string{}
	for _, kv := range strings.Split(q, "&") {
		kv = strings.TrimSpace(kv)
		if kv == "" {
			continue
		}
		eq := strings.Index(kv, "=")
		if eq < 0 {
			out[kv] = ""
			continue
		}
		out[kv[:eq]] = kv[eq+1:]
	}
	return out
}
