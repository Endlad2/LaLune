package main

import (
	"bufio"
	"fmt"
	"log"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// CoreManager — запускает ядро CSQTT, парсит его лог,
// поднимает TUN когда видит первый ненулевой «Активных»,
// и держит всё это в актуальном состоянии.
type CoreManager struct {
	store    *ConfigStore
	arch     string
	proc     *exec.Cmd
	bridge   *TunBridge
	state    *State
	mu       sync.Mutex
	logFile  *os.File
	running  bool
	stopCh   chan struct{}
	tunReady bool
}

// State — то, что мы пишем в StatusFile для LuCI.
type State struct {
	mu               sync.Mutex
	Connected        bool
	CoreVersion      string // то, что вернул LATEST при последнем успешном скачивании
	RemoteVersion    string // то, что LATEST говорит сейчас
	LastCoreError    string
	LastTunIP        string
	LastTunDNS       string
	ActiveSessions   int
	LastStatusUpdate int64
}

func NewCoreManager(store *ConfigStore, arch string, state *State) *CoreManager {
	return &CoreManager{
		store:  store,
		arch:   arch,
		state:  state,
		stopCh: make(chan struct{}),
	}
}

// ============ Парсинг логов ядра ============

var (
	// "Слушаю: 127.0.0.1:52230"
	reListen = regexp.MustCompile(`Слушаю:\s*127\.0\.0\.1:(\d+)`)

	// "TUNCONF:10.66.67.12:8.8.8.8"
	reTunconfColon = regexp.MustCompile(`TUNCONF:([\d.]+):([\d.,]+)`)

	// "Tunnel IP: 10.66.67.12 | DNS: 8.8.8.8,8.8.4.4"
	reTunconfLine = regexp.MustCompile(`Tunnel IP:\s*([\d.]+).*?DNS:\s*([\d.,]+)`)

	// "[СТАТИСТИКА] Активных: 3 | Траффик: 12345"
	reStat = regexp.MustCompile(`\[СТАТИСТИКА\]\s*Активных:\s*(\d+)\s*\|\s*Траффик:\s*(\d+)`)
)

// ============ Public ============

// Start запускает ядро с настройками и конфигом.
// listenPort — UDP-порт ядра, к которому будет подключён TUN.
func (m *CoreManager) Start(cfg Config, settings Settings) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.running {
		return fmt.Errorf("ядро уже запущено")
	}

	if !HasCore(m.arch) {
		return fmt.Errorf("ядро не найдено: %s", CorePath(m.arch))
	}

	corePath := CorePath(m.arch)
	listenPort := 52230 // фиксированный UDP-порт ядра для OpenWRT

	// Считаем total workers = workersPerHash * hashesCount (как на Desktop).
	hashes := strings.Split(cfg.Hashes, ",")
	hashesCount := 0
	for _, h := range hashes {
		if strings.TrimSpace(h) != "" {
			hashesCount++
		}
	}
	if hashesCount == 0 {
		hashesCount = 1
	}
	if hashesCount > 6 {
		hashesCount = 6
	}
	workers := settings.WorkersPerHash
	if workers < 9 {
		workers = 9
	}
	totalWorkers := workers * hashesCount

	args := []string{
		"-peer", cfg.Peer,
		"-password", cfg.Password,
		"-vk", cfg.Hashes,
		"-n", strconv.Itoa(totalWorkers),
		"-listen", fmt.Sprintf("127.0.0.1:%d", listenPort),
		"-obfs", settings.Obfs,
		"-fingerprint", settings.Fingerprint,
		"-client-ids", settings.ClientIds,
		"-vk-auth-mode", settings.VkAuthMode,
		"-captcha-mode", settings.CaptchaMode,
		"-device-id", settings.DeviceId,
	}

	logFile, err := os.OpenFile(CoreLogFile, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		return fmt.Errorf("open %s: %w", CoreLogFile, err)
	}
	m.logFile = logFile

	cmd := exec.Command(corePath, args...)
	cmd.Stdout = logFile
	cmd.Stderr = logFile

	if err := cmd.Start(); err != nil {
		logFile.Close()
		m.logFile = nil
		return fmt.Errorf("start core: %w", err)
	}
	m.proc = cmd
	m.running = true
	m.tunReady = false

	log.Printf("[CORE] запущен PID=%d: %s %s", cmd.Process.Pid, corePath, strings.Join(args, " "))

	m.state.mu.Lock()
	m.state.Connected = true
	m.state.LastCoreError = ""
	m.state.LastStatusUpdate = time.Now().Unix()
	m.state.mu.Unlock()
	WriteStatus(m.state)

	// Горутина парсинга логов
	go m.parseLog()

	// Горутина ожидания завершения процесса
	go func() {
		err := cmd.Wait()
		m.mu.Lock()
		m.running = false
		if m.bridge != nil {
			m.bridge.Cleanup()
			m.bridge = nil
		}
		m.tunReady = false
		if m.logFile != nil {
			m.logFile.Close()
			m.logFile = nil
		}
		m.mu.Unlock()

		m.state.mu.Lock()
		m.state.Connected = false
		m.state.ActiveSessions = 0
		if err != nil {
			m.state.LastCoreError = err.Error()
		}
		m.state.LastStatusUpdate = time.Now().Unix()
		m.state.mu.Unlock()
		WriteStatus(m.state)

		log.Printf("[CORE] процесс завершён: %v", err)
	}()

	return nil
}

// Stop останавливает ядро и снимает TUN.
func (m *CoreManager) Stop() error {
	m.mu.Lock()
	proc := m.proc
	bridge := m.bridge
	m.proc = nil
	m.bridge = nil
	m.tunReady = false
	m.mu.Unlock()

	if bridge != nil {
		bridge.Cleanup()
	}

	if proc != nil && proc.Process != nil {
		_ = proc.Process.Kill()
		log.Printf("[CORE] послали SIGKILL PID=%d", proc.Process.Pid)
	}

	m.state.mu.Lock()
	m.state.Connected = false
	m.state.ActiveSessions = 0
	m.state.LastStatusUpdate = time.Now().Unix()
	m.state.mu.Unlock()
	WriteStatus(m.state)

	return nil
}

func (m *CoreManager) IsRunning() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.running
}

// ============ Internal ============

// parseLog читает /var/log/lalune-core.log и реагирует на ключевые строки:
//   - TUNCONF / Tunnel IP:...DNS:... — запоминаем IP/DNS
//   - [СТАТИСТИКА] Активных: N | Траффик: M — при N>0 впервые поднимаем TUN
func (m *CoreManager) parseLog() {
	f, err := os.Open(CoreLogFile)
	if err != nil {
		log.Printf("[PARSER] не могу открыть лог ядра: %v", err)
		return
	}
	defer f.Close()

	reader := bufio.NewReader(f)
	var offset int64

	tunIP := ""
	tunDNS := ""
	corePort := 52230

	statTicker := time.NewTicker(2 * time.Second)
	defer statTicker.Stop()

	for {
		select {
		case <-m.stopCh:
			return
		default:
		}

		line, err := reader.ReadString('\n')
		if err != nil {
			// EOF — ждём новых данных
			time.Sleep(300 * time.Millisecond)
			// Обновляем offset чтобы не читать заново
			if pos, _ := f.Seek(0, 1); pos > offset {
				offset = pos
			}
			// Если процесс умер — выходим
			m.mu.Lock()
			running := m.running
			m.mu.Unlock()
			if !running {
				return
			}
			continue
		}

		offset += int64(len(line))
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		// Логируем в основной лог демона с префиксом
		log.Printf("[CORE] %s", line)

		// Слушаю: 127.0.0.1:PORT
		if matches := reListen.FindStringSubmatch(line); matches != nil {
			if p, err := strconv.Atoi(matches[1]); err == nil {
				corePort = p
			}
		}

		// TUNCONF:IP:DNS
		if matches := reTunconfColon.FindStringSubmatch(line); matches != nil {
			tunIP = matches[1]
			tunDNS = matches[2]
			m.recordTunconf(tunIP, tunDNS)
		}

		// Tunnel IP: ... | DNS: ...
		if matches := reTunconfLine.FindStringSubmatch(line); matches != nil {
			tunIP = strings.TrimSpace(matches[1])
			tunDNS = strings.TrimSpace(matches[2])
			m.recordTunconf(tunIP, tunDNS)
		}

		// [СТАТИСТИКА] Активных: N | Траффик: M
		if matches := reStat.FindStringSubmatch(line); matches != nil {
			n, _ := strconv.Atoi(matches[1])
			m.state.mu.Lock()
			m.state.ActiveSessions = n
			m.state.LastStatusUpdate = time.Now().Unix()
			m.state.mu.Unlock()
			WriteStatus(m.state)

			if n > 0 && !m.tunReady && tunIP != "" {
				m.mu.Lock()
				tunReady := m.tunReady
				m.mu.Unlock()
				if !tunReady {
					m.setupTun(tunIP, tunDNS, corePort)
				}
			}
		}
	}
}

func (m *CoreManager) recordTunconf(ip, dns string) {
	m.state.mu.Lock()
	m.state.LastTunIP = ip
	m.state.LastTunDNS = dns
	m.state.mu.Unlock()
	WriteStatus(m.state)
	log.Printf("[TUN] TUNCONF IP=%s DNS=%s", ip, dns)
}

func (m *CoreManager) setupTun(ip, dns string, corePort int) {
	m.mu.Lock()
	if m.tunReady {
		m.mu.Unlock()
		return
	}
	m.mu.Unlock()

	tunName := m.store.GetSettings().TunName
	if tunName == "" {
		tunName = "csqtt0"
	}

	bridge, err := NewTunBridge(tunName, corePort)
	if err != nil {
		log.Printf("[TUN] ошибка создания: %v", err)
		m.state.mu.Lock()
		m.state.LastCoreError = "tun: " + err.Error()
		m.state.mu.Unlock()
		WriteStatus(m.state)
		return
	}

	if err := bridge.SetupAddresses(ip, dns); err != nil {
		log.Printf("[TUN] ошибка настройки адресов: %v", err)
		bridge.Cleanup()
		m.state.mu.Lock()
		m.state.LastCoreError = "tun setup: " + err.Error()
		m.state.mu.Unlock()
		WriteStatus(m.state)
		return
	}

	bridge.Start()

	m.mu.Lock()
	m.bridge = bridge
	m.tunReady = true
	m.mu.Unlock()

	log.Printf("[TUN] %s поднят, мост активен (ядро на 127.0.0.1:%d)", tunName, corePort)
	WriteStatus(m.state)
}
