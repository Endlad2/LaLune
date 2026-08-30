//go:build !windows
// +build !windows

package main

import (
	"fmt"
	"net"
	"os/exec"
	"strings"

	"github.com/songgao/water"
)

// LinuxTun реализация TUN для Linux/Unix
type LinuxTun struct {
	app   *App
	iface *water.Interface
}

func init() {
	// Регистрируем фабрику для Linux
	newTun = func(app *App) TunInterface {
		return &LinuxTun{app: app}
	}
}

func (t *LinuxTun) AddLog(message string) {
	t.app.addLog(message)
}

func (t *LinuxTun) Setup() error {
	config := water.Config{
		DeviceType: water.TUN,
	}

	iface, err := water.New(config)
	if err != nil {
		return fmt.Errorf("не удалось создать TUN: %v", err)
	}

	t.iface = iface
	t.AddLog(fmt.Sprintf("[TUN] TUN устройство: %s", iface.Name()))
	return nil
}

func (t *LinuxTun) Start(udpConn net.Conn, running *bool) {
	if t.iface == nil {
		return
	}

	// TUN → UDP
	go func() {
		buf := make([]byte, 65535)
		for *running {
			n, err := t.iface.Read(buf)
			if err != nil {
				return
			}
			udpConn.Write(buf[:n])
		}
	}()

	// UDP → TUN
	go func() {
		buf := make([]byte, 65535)
		for *running {
			n, err := udpConn.Read(buf)
			if err != nil {
				return
			}
			t.iface.Write(buf[:n])
		}
	}()
}

func (t *LinuxTun) Stop() {
	if t.iface != nil {
		t.iface.Close()
		t.iface = nil
	}
}

func (t *LinuxTun) SetupRoutes(tunIP string, tunDNS string) {
	ifaceName := "csqtt0"
	if t.iface != nil {
		ifaceName = t.iface.Name()
	}

	exec.Command("ip", "addr", "add", tunIP+"/32", "dev", ifaceName).Run()
	exec.Command("ip", "link", "set", ifaceName, "up").Run()
	exec.Command("ip", "link", "set", ifaceName, "mtu", "1300").Run()

	dnsServers := strings.Split(tunDNS, ",")
	for _, dns := range dnsServers {
		if dns != "" {
			exec.Command("sh", "-c", fmt.Sprintf("echo 'nameserver %s' >> /etc/resolv.conf", dns)).Run()
		}
	}

	exec.Command("ip", "route", "add", "default", "dev", ifaceName).Run()
}

func (t *LinuxTun) CleanupRoutes() {
	exec.Command("ip", "route", "del", "default", "dev", "csqtt0").Run()
}
