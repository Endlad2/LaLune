//go:build windows
// +build windows

// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// platform_windows.go — Windows-реализация TUN и Runner для C-ABI.
// Wintun + UAC-запуск ядра.

package libs

import (
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

func init() {
	RegisterPlatformInit(func(core *AppCore) (*Bridge, error) {
		tun := &WindowsTun{core: core}
		runner := &WindowsRunner{core: core}
		return NewBridge(core, tun, runner), nil
	})
}

// ============ Wintun ============

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

// ============ Windows TUN ============

type WindowsTun struct {
	core         *AppCore
	adapter      uintptr
	session      uintptr
	hasSession   bool
	bypassRoutes []string
	gateway      string
	mu           sync.Mutex
}

func (t *WindowsTun) Setup() error {
	dllPath := filepath.Join(t.core.GetAppDir(), "wintun.dll")
	if err := initWintun(dllPath); err != nil {
		return err
	}
	if t.adapter == 0 {
		if adapter, err := wintunOpenAdapter("CSQTT"); err == nil {
			t.adapter = adapter
			t.core.AddLog("[TUN] Адаптер CSQTT уже существует, открыт")
		}
	}
	if t.adapter == 0 {
		t.core.AddLog("[TUN] Создание Wintun адаптера...")
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
	t.core.AddLog("[TUN] Wintun адаптер готов")
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
		t.core.AddLog(fmt.Sprintf("[TUN] Физический шлюз: %s", t.gateway))
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
	t.core.AddLog("[TUN] Маршруты настроены")
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

// ============ Windows Runner ============

type WindowsRunner struct {
	core *AppCore
}

func (r *WindowsRunner) StartCore(cmdArgs []string, listenPort int, bridge *Bridge) {
	r.startCoreWithUAC(cmdArgs, listenPort, bridge)
}

func (r *WindowsRunner) startCoreWithUAC(cmdArgs []string, listenPort int, bridge *Bridge) {
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
										tun.mu.Lock()
										tun.bypassRoutes = append(tun.bypassRoutes, match)
										tun.mu.Unlock()
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
