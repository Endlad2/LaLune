//go:build windows
// +build windows

package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

import "lalune-desktop/Libs"

// ============ Wintun DLL ============

var (
	wintunDLL          *syscall.DLL
	procCreateAdapter  *syscall.Proc
	procOpenAdapter    *syscall.Proc
	procCloseAdapter   *syscall.Proc
	procStartSession   *syscall.Proc
	procEndSession     *syscall.Proc
	procReceivePacket  *syscall.Proc
	procReleaseReceive *syscall.Proc
	procAllocateSend   *syscall.Proc
	procSendPacket     *syscall.Proc
)

func initWintun(dllPath string) error {
	if wintunDLL != nil {
		return nil
	}
	dll, err := syscall.LoadDLL(dllPath)
	if err != nil {
		return fmt.Errorf("не удалось загрузить wintun.dll: %v", err)
	}
	wintunDLL = dll
	procCreateAdapter = dll.MustFindProc("WintunCreateAdapter")
	procOpenAdapter = dll.MustFindProc("WintunOpenAdapter")
	procCloseAdapter = dll.MustFindProc("WintunCloseAdapter")
	procStartSession = dll.MustFindProc("WintunStartSession")
	procEndSession = dll.MustFindProc("WintunEndSession")
	procReceivePacket = dll.MustFindProc("WintunReceivePacket")
	procReleaseReceive = dll.MustFindProc("WintunReleaseReceivePacket")
	procAllocateSend = dll.MustFindProc("WintunAllocateSendPacket")
	procSendPacket = dll.MustFindProc("WintunSendPacket")
	return nil
}

func wintunCreateAdapter(name, tunnelType string) (uintptr, error) {
	namePtr, _ := syscall.UTF16PtrFromString(name)
	typePtr, _ := syscall.UTF16PtrFromString(tunnelType)
	ret, _, _ := procCreateAdapter.Call(
		uintptr(unsafe.Pointer(namePtr)), uintptr(unsafe.Pointer(typePtr)), 0)
	if ret == 0 {
		return 0, fmt.Errorf("WintunCreateAdapter failed")
	}
	return ret, nil
}

func wintunOpenAdapter(name string) (uintptr, error) {
	namePtr, _ := syscall.UTF16PtrFromString(name)
	ret, _, _ := procOpenAdapter.Call(uintptr(unsafe.Pointer(namePtr)))
	if ret == 0 {
		return 0, fmt.Errorf("WintunOpenAdapter failed")
	}
	return ret, nil
}

func wintunCloseAdapter(adapter uintptr)       { procCloseAdapter.Call(adapter) }
func wintunEndSession(session uintptr)         { procEndSession.Call(session) }
func wintunSendPacket(session, packet uintptr) { procSendPacket.Call(session, packet) }

func wintunStartSession(adapter uintptr, capacity uint32) (uintptr, error) {
	ret, _, _ := procStartSession.Call(adapter, uintptr(capacity))
	if ret == 0 {
		return 0, fmt.Errorf("WintunStartSession failed")
	}
	return ret, nil
}

func wintunReceivePacket(session uintptr) ([]byte, error) {
	var size uint32
	ret, _, _ := procReceivePacket.Call(session, uintptr(unsafe.Pointer(&size)))
	if ret == 0 {
		return nil, fmt.Errorf("no packet")
	}
	packet := make([]byte, size)
	copy(packet, unsafe.Slice((*byte)(unsafe.Pointer(ret)), int(size)))
	procReleaseReceive.Call(session, ret)
	return packet, nil
}

func wintunAllocateSendPacket(session uintptr, size uint32) (uintptr, error) {
	ret, _, _ := procAllocateSend.Call(session, uintptr(size))
	if ret == 0 {
		return 0, fmt.Errorf("WintunAllocateSendPacket failed")
	}
	return ret, nil
}

// ============ ShellExecuteEx ============

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

// ============ App ============

type App struct {
	core    *libs.AppCore
	bridge  *libs.Bridge
	tun     *WindowsTun
	runner  *WindowsRunner
	isAdmin bool
}

type WindowsTun struct {
	app          *App
	adapter      uintptr
	session      uintptr
	hasSession   bool
	bypassRoutes []string
	gateway      string
	mu           sync.Mutex
}

func (t *WindowsTun) Setup() error {
	dllPath := filepath.Join(t.app.core.GetAppDir(), "wintun.dll")
	if err := initWintun(dllPath); err != nil {
		return err
	}
	if t.adapter == 0 {
		if adapter, err := wintunOpenAdapter("CSQTT"); err == nil {
			t.adapter = adapter
			t.app.core.AddLog("[TUN] Адаптер CSQTT уже существует, открыт")
		}
	}
	if t.adapter == 0 {
		t.app.core.AddLog("[TUN] Создание Wintun адаптера...")
		adapter, err := wintunCreateAdapter("CSQTT", "Wintun")
		if err != nil {
			return fmt.Errorf("не удалось создать Wintun адаптер: %v", err)
		}
		t.adapter = adapter
	}
	if !t.hasSession {
		session, err := wintunStartSession(t.adapter, 0x400000)
		if err != nil {
			wintunCloseAdapter(t.adapter)
			t.adapter = 0
			return fmt.Errorf("не удалось открыть сессию: %v", err)
		}
		t.session = session
		t.hasSession = true
	}
	t.app.core.AddLog("[TUN] Wintun адаптер готов")
	return nil
}

func (t *WindowsTun) Start(udpConn net.Conn, running *bool) {
	go func() {
		for *running {
			packet, err := wintunReceivePacket(t.session)
			if err != nil {
				if *running {
					time.Sleep(2 * time.Millisecond)
					continue
				}
				return
			}
			udpConn.Write(packet)
		}
	}()
	go func() {
		buf := make([]byte, 65535)
		for *running {
			n, err := udpConn.Read(buf)
			if err != nil {
				return
			}
			packet, err := wintunAllocateSendPacket(t.session, uint32(n))
			if err != nil {
				continue
			}
			copy(unsafe.Slice((*byte)(unsafe.Pointer(packet)), n), buf[:n])
			wintunSendPacket(t.session, packet)
		}
	}()
}

func (t *WindowsTun) Stop() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.hasSession {
		wintunEndSession(t.session)
		t.session = 0
		t.hasSession = false
	}
	if t.adapter != 0 {
		wintunCloseAdapter(t.adapter)
		t.adapter = 0
	}
}

func (t *WindowsTun) SetupRoutes(tunIP, tunDNS string) {
	t.mu.Lock()
	defer t.mu.Unlock()

	t.gateway = getPhysicalGateway()
	if t.gateway != "" {
		t.app.core.AddLog(fmt.Sprintf("[TUN] Физический шлюз: %s", t.gateway))
	}
	for _, ip := range t.bypassRoutes {
		if t.gateway != "" {
			exec.Command("route", "ADD", ip, "MASK", "255.255.255.255", t.gateway, "METRIC", "1").Run()
		}
	}
	exec.Command("netsh", "interface", "ipv4", "set", "address",
		"name=\"CSQTT\"", "source=static", "address="+tunIP, "mask=255.255.255.255").Run()
	exec.Command("netsh", "interface", "ipv4", "set", "subinterface",
		"\"CSQTT\"", "mtu=1300", "store=active").Run()

	dnsIndex := 1
	for _, dns := range strings.Split(tunDNS, ",") {
		dns = strings.TrimSpace(dns)
		if dns != "" && dnsIndex <= 2 {
			exec.Command("netsh", "interface", "ipv4", "add", "dnsservers",
				"name=\"CSQTT\"", "address="+dns,
				fmt.Sprintf("index=%d", dnsIndex), "validate=no").Run()
			dnsIndex++
		}
	}
	exec.Command("netsh", "interface", "ipv4", "add", "route",
		"prefix=0.0.0.0/0", "interface=\"CSQTT\"",
		"nexthop=0.0.0.0", "metric=5", "store=active").Run()
	t.app.core.AddLog("[TUN] Маршруты настроены")
}

func (t *WindowsTun) CleanupRoutes() {
	t.mu.Lock()
	defer t.mu.Unlock()
	exec.Command("netsh", "interface", "ipv4", "delete", "route",
		"prefix=0.0.0.0/0", "interface=\"CSQTT\"", "store=active").Run()
	for _, ip := range t.bypassRoutes {
		exec.Command("route", "DELETE", ip).Run()
	}
	t.bypassRoutes = nil
	t.gateway = ""
}

func (t *WindowsTun) AddBypassRoute(ip string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if net.ParseIP(ip) == nil {
		return
	}
	for _, existing := range t.bypassRoutes {
		if existing == ip {
			return
		}
	}
	if t.gateway != "" {
		exec.Command("route", "ADD", ip, "MASK", "255.255.255.255", t.gateway, "METRIC", "1").Run()
	}
	t.bypassRoutes = append(t.bypassRoutes, ip)
}

func getPhysicalGateway() string {
	out, err := exec.Command("cmd", "/c", "route", "print", "0.0.0.0").Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.Contains(line, "0.0.0.0") {
			fields := strings.Fields(line)
			if len(fields) >= 3 && fields[0] == "0.0.0.0" {
				return fields[2]
			}
		}
	}
	return ""
}

// ============ Ядро CSQTT: kill по имени процесса ============

// CoreProcessNames — имена процессов ядра CSQTT на Windows.
// Их может быть несколько вариантов в зависимости от сборки.
var CoreProcessNames = []string{
	"client-windows-x86_64.exe",
	"client-windows-x86_64",
	"client-windows-amd64.exe",
	"csqtt-client.exe",
}

// KillCoreProcesses ищет процессы ядра по имени через tasklist и убивает
// через taskkill. Возвращает количество убитых процессов.
//
// Нужен потому, что ядро на Windows запускается через ShellExecuteEx с
// runas (UAC) — handle процесса не сохраняется в cmd.Process, и обычный
// Process.Kill() не работает. Приходится искать по имени.
func KillCoreProcesses(log func(string)) int {
	killed := 0

	for _, name := range CoreProcessNames {
		// tasklist /FI "IMAGENAME eq <name>" /FO CSV /NH
		// Ищем точное совпадение по имени файла.
		out, err := exec.Command(
			"tasklist",
			"/FI", "IMAGENAME eq "+name,
			"/FO", "CSV",
			"/NH",
		).Output()
		if err != nil {
			// tasklist может ругаться, если процессов нет — это норма.
			continue
		}

		output := string(out)
		if !strings.Contains(strings.ToLower(output), strings.ToLower(name)) {
			continue
		}

		if log != nil {
			log(fmt.Sprintf("[KILL] Найден процесс ядра: %s", name))
		}

		// taskkill /F /IM <name> /T — /T убивает дочерние процессы.
		killCmd := exec.Command("taskkill", "/F", "/T", "/IM", name)
		killOut, killErr := killCmd.CombinedOutput()
		if killErr != nil {
			if log != nil {
				log(fmt.Sprintf("[KILL] taskkill %s: %v (%s)",
					name, killErr, strings.TrimSpace(string(killOut))))
			}
			continue
		}

		killed++
		if log != nil {
			log(fmt.Sprintf("[KILL] Процесс убит: %s", name))
		}
	}

	return killed
}

// ============ Runner ============

type WindowsRunner struct {
	app *App
}

func (r *WindowsRunner) StartCore(cmdArgs []string, listenPort int, bridge *libs.Bridge) {
	r.startCoreWithUAC(cmdArgs, listenPort, bridge)
}

func (r *WindowsRunner) startCoreWithUAC(cmdArgs []string, listenPort int, bridge *libs.Bridge) {
	logFile := filepath.Join(os.TempDir(), "csqtt_core_logs.txt")
	batPath := filepath.Join(os.TempDir(), "lalune_start_core.bat")
	os.Remove(logFile)

	quotedArgs := make([]string, len(cmdArgs)-1)
	for i, arg := range cmdArgs[1:] {
		escaped := strings.ReplaceAll(arg, "\"", "\\\"")
		quotedArgs[i] = "\"" + escaped + "\""
	}

	batContent := fmt.Sprintf("@echo off\r\n\"%s\" %s > \"%s\" 2>&1\r\n",
		cmdArgs[0], strings.Join(quotedArgs, " "), logFile)
	os.WriteFile(batPath, []byte(batContent), 0644)

	bridge.Core.AddLog("[INFO] Запуск ядра через UAC...")
	if err := runAsAdminWithBat(batPath); err != nil {
		bridge.Core.AddLog(fmt.Sprintf("[ERROR] Не удалось запустить от админа: %v", err))
		bridge.Core.SetConnected(false)
		return
	}
	bridge.Core.AddLog("[INFO] Ядро запущено от администратора")

	type TunConf struct {
		IP, DNS string
		Port    int
	}
	tunconfChan := make(chan TunConf, 1)
	trafficDetectedChan := make(chan bool, 1)
	transportIPs := make(map[string]bool)
	var transportMu sync.Mutex
	coreListenPort := 52230
	lastOffset := int64(0)

	listenRe := regexp.MustCompile(`Слушаю:\s*127\.0\.0\.1:(\d+)`)
	ipv4Re := regexp.MustCompile(`\d+\.\d+\.\d+\.\d+`)
	statRe := regexp.MustCompile(`Активных:\s*(\d+)`)

	go func() {
		for bridge.Core.IsConnected() {
			if file, err := os.Open(logFile); err == nil {
				file.Seek(lastOffset, 0)
				content, _ := os.ReadFile(logFile)
				if int64(len(content)) > lastOffset {
					newContent := string(content[lastOffset:])
					lastOffset = int64(len(content))

					for _, line := range strings.Split(newContent, "\n") {
						line = strings.TrimSpace(line)
						if line == "" || strings.Contains(line, "__CSQTT_EVENT__|STOPPED|") {
							continue
						}
						bridge.Core.AddLog(line)

						if m := listenRe.FindStringSubmatch(line); m != nil {
							fmt.Sscanf(m[1], "%d", &coreListenPort)
						}
						if strings.Contains(line, "TURN") || strings.Contains(line, "Relay") {
							for _, match := range ipv4Re.FindAllString(line, -1) {
								transportMu.Lock()
								if !transportIPs[match] {
									transportIPs[match] = true
									if tun, ok := bridge.Tun.(*WindowsTun); ok {
										tun.AddBypassRoute(match)
									}
								}
								transportMu.Unlock()
							}
						}
						tunIP, tunDNS := bridge.ParseTunconf(line)
						if tunIP != "" && tunDNS != "" {
							select {
							case tunconfChan <- TunConf{IP: tunIP, DNS: tunDNS, Port: coreListenPort}:
							default:
							}
						}
						if m := statRe.FindStringSubmatch(line); m != nil {
							var active int
							fmt.Sscanf(m[1], "%d", &active)
							if active > 0 {
								select {
								case trafficDetectedChan <- true:
								default:
								}
							}
						}
					}
				}
				file.Close()
			}
			time.Sleep(500 * time.Millisecond)
		}
	}()

	go func() {
		var conf TunConf
		hasConf, hasTraffic := false, false
		for !hasConf || !hasTraffic {
			select {
			case c := <-tunconfChan:
				conf = c
				hasConf = true
				bridge.Core.AddLog(fmt.Sprintf("[TUN] TUNCONF: IP=%s DNS=%s Port=%d", c.IP, c.DNS, c.Port))
			case <-trafficDetectedChan:
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
		if err := bridge.SetupTun(); err != nil {
			bridge.Core.AddLog(fmt.Sprintf("[TUN] Ошибка: %v", err))
		} else {
			bridge.SetupRoutes(conf.IP, conf.DNS)
			bridge.StartTunnel(conf.Port)
			bridge.Core.AddLog("[TUN] Туннель запущен")
		}
	}()

	go func() {
		for bridge.Core.IsConnected() {
			time.Sleep(1 * time.Second)
		}
		bridge.StopTunnel()
		bridge.CleanupRoutes()
	}()
}

// ============ Startup ============

func NewApp() *App {
	core := libs.NewAppCore()
	tun := &WindowsTun{}
	app := &App{core: core, tun: tun}
	tun.app = app
	app.runner = &WindowsRunner{app: app}
	app.bridge = libs.NewBridge(core, tun, app.runner)
	return app
}

func (a *App) startup(ctx context.Context) {
	a.isAdmin = isAdmin()
	a.core.Startup(ctx)
	a.core.LoadConfigs()
	if a.isAdmin {
		a.core.AddLog("[INFO] Запущено от администратора")
	} else {
		a.core.AddLog("[INFO] Запущено без прав администратора")
	}
	a.ensureWintun()
}

func isAdmin() bool {
	_, err := os.Open("\\\\.\\PHYSICALDRIVE1")
	if err == nil {
		return true
	}
	_, err = os.Open("\\\\.\\PHYSICALDRIVE0")
	return err == nil
}

func (a *App) ensureWintun() bool {
	if _, err := libs.DownloadAndExtractWintun(a.core.GetAppDir()); err != nil {
		a.core.AddLog(fmt.Sprintf("[WINTUN] Ошибка: %v", err))
		return false
	}
	a.core.AddLog("[WINTUN] wintun.dll готов")
	return true
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

// ============ API ============

func (a *App) GetConfigsJson() string  { return a.core.GetConfigsJson() }
func (a *App) GetSettingsJson() string { return a.core.GetSettingsJson() }
func (a *App) GetLogsJson() string     { return a.core.GetLogsJson() }
func (a *App) GetStatusJson() string   { return fmt.Sprintf(`{"connected":%v}`, a.core.IsConnected()) }
func (a *App) SaveConfig(link string) bool {
	return a.core.SaveConfigWithProtocol(link, "")
}

func (a *App) SaveConfigWithProtocol(link string, protocol string) bool {
	return a.core.SaveConfigWithProtocol(link, protocol)
}
func (a *App) DeleteConfig(id int64) bool { return a.core.DeleteConfig(id) }
func (a *App) SaveSettings(j string) bool { return a.core.SaveSettings(j) }
func (a *App) ClearLogs() bool            { return a.core.ClearLogs() }
func (a *App) UpdateCore() bool           { return a.core.UpdateCore() }
func (a *App) Connect(id int64) bool      { return a.bridge.Connect(id) }

// Disconnect — останавливает туннель, TUN и убивает процесс ядра.
// На Windows ядро запускается через UAC (ShellExecuteEx), поэтому
// handle процесса недоступен — ищем по имени через tasklist/taskkill.
func (a *App) Disconnect() bool {
	a.core.AddLog("[INFO] Отключение...")

	// 1) Сначала помечаем, что мы отключены — это остановит логгеры и watcher'ы.
	a.core.SetConnected(false)

	// 2) Убиваем процесс ядра по имени (до остановки TUN, чтобы
	//    ядро не успело ничего дописать в лог).
	killed := KillCoreProcesses(func(s string) {
		a.core.AddLog(s)
	})
	if killed == 0 {
		a.core.AddLog("[KILL] Процессы ядра не найдены (возможно, уже остановлены)")
	}

	// 3) Останавливаем TUN и мост, чистим маршруты.
	result := a.bridge.Disconnect()

	return result
}

// Глобальный конфиг (для вкладки Настройки).
func (a *App) GetSelectedConfigJson() string       { return a.core.GetSelectedConfigJson() }
func (a *App) SetSelectedConfigJson(j string) bool { return a.core.SetSelectedConfigJson(j) }

// Флаг «ядро скачивается».
func (a *App) IsCoreDownloading() bool { return a.core.IsCoreDownloading() }

func (a *App) CheckUpdate() string {
	version, hasUpdate, err := a.core.CheckUpdateSync()
	if err != nil {
		return fmt.Sprintf(`{"error":"%s"}`, err.Error())
	}
	return fmt.Sprintf(`{"update":%v,"version":"%s"}`, hasUpdate, version)
}

func (a *App) UpdateCoreAndWait() bool {
	if a.core.IsConnected() {
		a.Disconnect()
		time.Sleep(1 * time.Second)
	}
	remote := a.core.FetchLatestVersion()
	if remote == "" {
		return false
	}
	a.core.PerformUpdate(remote)
	return true
}

func (a *App) CheckLaLuneUpdate() libs.LaLuneUpdateResult {
	return a.core.CheckLaLuneUpdate()
}

func (a *App) OpenLaLuneReleasesURL() string {
	return a.core.OpenLaLuneReleasesURL()
}

func (a *App) GetVKTokenState() libs.VkTokenState {
	return a.core.GetVKTokenState()
}

func (a *App) ValidateVKToken() libs.VkTokenState {
	return a.core.ValidateVKToken()
}

func (a *App) LoginVK() bool {
	ch := a.core.StartVKTokenFetcher()
	go func() {
		for st := range ch {
			if st.Message != "" {
				a.core.AddLog("[VK] " + st.Message)
			}
		}
	}()
	return true
}

func (a *App) DeleteVKToken() bool { return a.core.DeleteVKToken() }

func (a *App) RunVkAutoApiCalls() string {
	hashes, callIds, err := a.core.RunVkAutoApiCalls(func(s string) {
		a.core.AddLog(s)
	})
	if err != nil {
		return fmt.Sprintf(`{"error":%q}`, err.Error())
	}
	return fmt.Sprintf(`{"hashes":%s,"callIds":%s}`,
		jsonStringArrayWin(hashes), jsonStringArrayWin(callIds))
}

func (a *App) PollAutoApiResult() string { return `{"pending":false}` }

func (a *App) FinishVkCalls(callIds []string) bool {
	a.core.FinishVkCalls(callIds)
	return true
}

func jsonStringArrayWin(items []string) string {
	if len(items) == 0 {
		return "[]"
	}
	q := make([]string, len(items))
	for i, s := range items {
		s = strings.ReplaceAll(s, `\`, `\\`)
		s = strings.ReplaceAll(s, `"`, `\"`)
		q[i] = `"` + s + `"`
	}
	return "[" + strings.Join(q, ",") + "]"
}
