//go:build linux
// +build linux

// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// platform_linux.go — Linux-реализация TUN и Runner для C-ABI.

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
)

func init() {
	RegisterPlatformInit(func(core *AppCore) (*Bridge, error) {
		tun := &LinuxTun{core: core}
		runner := &LinuxRunner{core: core}
		return NewBridge(core, tun, runner), nil
	})
}

// ============ Linux TUN ============

type LinuxTun struct {
	core         *AppCore
	bypassRoutes []string
	mu           sync.Mutex
}

func (t *LinuxTun) Setup() error { return nil }
func (t *LinuxTun) Start(_ net.Conn, _ *bool) {}
func (t *LinuxTun) Stop() {}

func (t *LinuxTun) SetupRoutes(tunIP, tunDNS string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.core.AddLog(fmt.Sprintf("[TUN] Настройка TUN (IP: %s, DNS: %s)...", tunIP, tunDNS))

	cmd := fmt.Sprintf("ip tuntap add dev csqtt0 mode tun && ip addr add %s/32 dev csqtt0 && ip link set csqtt0 up && ip link set csqtt0 mtu 1300", tunIP)
	t.runSudo(cmd)

	for _, dns := range strings.Split(tunDNS, ",") {
		dns = strings.TrimSpace(dns)
		if dns != "" {
			t.runSudo(fmt.Sprintf("echo 'nameserver %s' >> /etc/resolv.conf", dns))
		}
	}
	t.runSudo("ip route add default dev csqtt0")
	t.core.AddLog("[TUN] TUN настроен успешно")
}

func (t *LinuxTun) CleanupRoutes() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.core.AddLog("[TUN] Удаление TUN...")
	t.runSudo("ip route del default dev csqtt0 2>/dev/null || true")
	t.runSudo("ip tuntap del dev csqtt0 mode tun 2>/dev/null || true")
	t.core.AddLog("[TUN] TUN удалён")
}

func (t *LinuxTun) runSudo(command string) error {
	fullCmd := "sudo " + command
	cmd := exec.Command("sh", "-c", fullCmd)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// ============ Linux Runner ============

type LinuxRunner struct {
	core *AppCore
}

func (r *LinuxRunner) StartCore(cmdArgs []string, listenPort int, bridge *Bridge) {
	r.startCoreWithSudo(cmdArgs, listenPort, bridge)
}

func (r *LinuxRunner) startCoreWithSudo(cmdArgs []string, listenPort int, bridge *Bridge) {
	logFile := filepath.Join(os.TempDir(), "lalune_core_logs.txt")
	os.Remove(logFile)

	corePath := cmdArgs[0]
	quotedArgs := make([]string, len(cmdArgs)-1)
	for i, arg := range cmdArgs[1:] {
		escaped := strings.ReplaceAll(arg, "'", "'\\''")
		quotedArgs[i] = "'" + escaped + "'"
	}

	cmdLine := fmt.Sprintf("'%s' %s > '%s' 2>&1",
		strings.ReplaceAll(corePath, "'", "'\\''"),
		strings.Join(quotedArgs, " "),
		logFile,
	)

	bridge.Core.AddLog("[INFO] Запуск ядра через sudo...")

	cmd := exec.Command("sh", "-c", "sudo "+cmdLine)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		bridge.Core.AddLog(fmt.Sprintf("[ERROR] Не удалось запустить: %v", err))
		bridge.Core.SetConnected(false)
		return
	}

	bridge.Core.AddLog(fmt.Sprintf("[INFO] Ядро запущено (PID: %d)", cmd.Process.Pid))

	tunconfChan := make(chan [2]string, 1)
	trafficChan := make(chan bool, 1)
	lastOffset := int64(0)

	listenRe := regexp.MustCompile(`Слушаю:\s*127\.0\.0\.1:(\d+)`)
	statRe := regexp.MustCompile(`Активных:\s*(\d+)`)
	coreListenPort := 52230

	go func() {
		for bridge.Core.IsConnected() {
			if content, err := os.ReadFile(logFile); err == nil {
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
							bridge.Core.AddLog(fmt.Sprintf("[TUN] Порт ядра: %d", coreListenPort))
						}
						tunIP, tunDNS := bridge.ParseTunconf(line)
						if tunIP != "" && tunDNS != "" {
							select {
							case tunconfChan <- [2]string{tunIP, tunDNS}:
							default:
							}
						}
						if m := statRe.FindStringSubmatch(line); m != nil {
							var active int
							fmt.Sscanf(m[1], "%d", &active)
							if active > 0 {
								select {
								case trafficChan <- true:
								default:
								}
							}
						}
					}
				}
			}
			time.Sleep(500 * time.Millisecond)
		}
	}()

	go func() {
		var tunIP, tunDNS string
		hasConf, hasTraffic := false, false
		for !hasConf || !hasTraffic {
			select {
			case conf := <-tunconfChan:
				tunIP, tunDNS = conf[0], conf[1]
				hasConf = true
				bridge.Core.AddLog(fmt.Sprintf("[TUN] TUNCONF: IP=%s DNS=%s", tunIP, tunDNS))
			case <-trafficChan:
				hasTraffic = true
				bridge.Core.AddLog("[TUN] Трафик обнаружен")
			case <-time.After(90 * time.Second):
				bridge.Core.AddLog("[TUN] Таймаут ожидания")
				bridge.Core.SetConnected(false)
				return
			}
		}
		bridge.Core.AddLog("[TUN] Настройка TUN...")
		time.Sleep(750 * time.Millisecond)
		if tun, ok := bridge.Tun.(*LinuxTun); ok {
			tun.SetupRoutes(tunIP, tunDNS)
		}
	}()

	go func() {
		cmd.Wait()
		bridge.Core.AddLog("=== Процесс завершён ===")
		bridge.Core.SetConnected(false)
		bridge.StopTunnel()
		bridge.CleanupRoutes()
	}()
}

// ensure syscall import is used
var _ = syscall.SIGTERM
