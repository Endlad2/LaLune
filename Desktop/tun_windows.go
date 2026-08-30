//go:build windows
// +build windows

package main

import (
	"fmt"
	"net"
	"os/exec"
	"strings"

	"golang.zx2c4.com/wintun"
)

// WindowsTun реализация TUN для Windows
type WindowsTun struct {
	app        *App
	adapter    *wintun.Adapter
	session    wintun.Session
	hasSession bool
}

func init() {
	// Регистрируем фабрику для Windows
	newTun = func(app *App) TunInterface {
		return &WindowsTun{app: app}
	}
}

func (t *WindowsTun) AddLog(message string) {
	t.app.addLog(message)
}

func (t *WindowsTun) Setup() error {
	adapter, err := wintun.CreateAdapter("CSQTT", "Wintun", nil)
	if err != nil {
		adapter, err = wintun.OpenAdapter("CSQTT")
		if err != nil {
			return fmt.Errorf("не удалось создать Wintun адаптер: %v", err)
		}
	}

	t.adapter = adapter

	session, err := adapter.StartSession(0x400000)
	if err != nil {
		adapter.Close()
		return fmt.Errorf("не удалось открыть сессию: %v", err)
	}

	t.session = session
	t.hasSession = true
	t.AddLog("[TUN] Wintun адаптер создан")
	return nil
}

func (t *WindowsTun) Start(udpConn net.Conn, running *bool) {
	// TUN → UDP
	go func() {
		for *running {
			packet, err := t.session.ReceivePacket()
			if err != nil {
				continue
			}
			udpConn.Write(packet)
			t.session.ReleaseReceivePacket(packet)
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
			packet, err := t.session.AllocateSendPacket(n)
			if err != nil {
				continue
			}
			copy(packet, buf[:n])
			t.session.SendPacket(packet)
		}
	}()
}

func (t *WindowsTun) Stop() {
	if t.hasSession {
		t.session.End()
		t.hasSession = false
	}
	if t.adapter != nil {
		t.adapter.Close()
		t.adapter = nil
	}
}

func (t *WindowsTun) SetupRoutes(tunIP string, tunDNS string) {
	exec.Command("netsh", "interface", "ipv4", "set", "address", "name=\"CSQTT\"", "source=static", "address="+tunIP, "mask=255.255.255.255").Run()
	exec.Command("netsh", "interface", "ipv4", "set", "subinterface", "\"CSQTT\"", "mtu=1300", "store=active").Run()

	dnsServers := strings.Split(tunDNS, ",")
	for i, dns := range dnsServers {
		if dns != "" && i < 2 {
			exec.Command("netsh", "interface", "ipv4", "add", "dnsservers", "name=\"CSQTT\"", "address="+dns, fmt.Sprintf("index=%d", i+1), "validate=no").Run()
		}
	}

	exec.Command("netsh", "interface", "ipv4", "add", "route", "prefix=0.0.0.0/0", "interface=\"CSQTT\"", "nexthop=0.0.0.0", "metric=5", "store=active").Run()
}

func (t *WindowsTun) CleanupRoutes() {
	exec.Command("netsh", "interface", "ipv4", "delete", "route", "prefix=0.0.0.0/0", "interface=\"CSQTT\"", "store=active").Run()
}
