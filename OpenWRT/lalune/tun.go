package main

import (
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	"github.com/songgao/water"
)

// TunBridge — TUN-интерфейс csqtt0 плюс UDP-мост к ядру.
//
// Схема:
//   [kernel routing] -> csqtt0 (TUN) -> читаем пакеты -> UDP -> 127.0.0.1:<corePort> -> ядро
//   ядро -> UDP -> читаем пакеты -> пишем в csqtt0 (TUN) -> [kernel routing]
//
// Дефолтный маршрут НЕ трогаем. Пользователь сам через firewall/network
// решает, какие пакеты пойдут в csqtt0.
type TunBridge struct {
	iface    *water.Interface
	tunName  string
	coreAddr string
	udp      *net.UDPConn
	running  bool
	mu       sync.Mutex
	stopCh   chan struct{}
}

// NewTunBridge создаёт TUN с указанным именем и готовит UDP-соединение к ядру.
func NewTunBridge(tunName string, corePort int) (*TunBridge, error) {
	cfg := water.Config{
		DeviceType: water.TUN,
	}
	cfg.Name = tunName

	iface, err := water.New(cfg)
	if err != nil {
		return nil, fmt.Errorf("water.New(%s): %w", tunName, err)
	}

	coreAddr := fmt.Sprintf("127.0.0.1:%d", corePort)
	udpAddr, err := net.ResolveUDPAddr("udp", coreAddr)
	if err != nil {
		iface.Close()
		return nil, fmt.Errorf("resolve %s: %w", coreAddr, err)
	}
	udpConn, err := net.DialUDP("udp", nil, udpAddr)
	if err != nil {
		iface.Close()
		return nil, fmt.Errorf("dial udp %s: %w", coreAddr, err)
	}

	return &TunBridge{
		iface:    iface,
		tunName:  tunName,
		coreAddr: coreAddr,
		udp:      udpConn,
		stopCh:   make(chan struct{}),
	}, nil
}

// Name возвращает имя TUN-интерфейса.
func (t *TunBridge) Name() string {
	return t.tunName
}

// Start запускает два goroutine: TUN→UDP и UDP→TUN.
func (t *TunBridge) Start() {
	t.mu.Lock()
	if t.running {
		t.mu.Unlock()
		return
	}
	t.running = true
	t.mu.Unlock()

	go t.tunToUDP()
	go t.udpToTun()
}

func (t *TunBridge) tunToUDP() {
	buf := make([]byte, 65535)
	for {
		select {
		case <-t.stopCh:
			return
		default:
		}

		t.iface.SetReadDeadline(time.Now().Add(1 * time.Second))
		n, err := t.iface.Read(buf)
		if err != nil {
			if isTimeout(err) {
				continue
			}
			// TUN закрыт — выходим
			return
		}
		if n > 0 {
			if _, err := t.udp.Write(buf[:n]); err != nil {
				log.Printf("[TUN] udp write error: %v", err)
			}
		}
	}
}

func (t *TunBridge) udpToTun() {
	buf := make([]byte, 65535)
	for {
		select {
		case <-t.stopCh:
			return
		default:
		}

		t.udp.SetReadDeadline(time.Now().Add(1 * time.Second))
		n, err := t.udp.Read(buf)
		if err != nil {
			if isTimeout(err) {
				continue
			}
			return
		}
		if n > 0 {
			if _, err := t.iface.Write(buf[:n]); err != nil {
				log.Printf("[TUN] iface write error: %v", err)
			}
		}
	}
}

// SetupAddresses настраивает адрес, MTU и поднимает интерфейс.
// tunIP — адрес из TUNCONF (без маски), tunDNS — список DNS через запятую.
func (t *TunBridge) SetupAddresses(tunIP, tunDNS string) error {
	// ip addr add <ip>/32 dev <iface>
	if err := execCommand("ip", "addr", "add", tunIP+"/32", "dev", t.tunName); err != nil {
		return fmt.Errorf("ip addr add: %w", err)
	}

	// ip link set <iface> mtu 1300
	if err := execCommand("ip", "link", "set", t.tunName, "mtu", "1300"); err != nil {
		return fmt.Errorf("ip link set mtu: %w", err)
	}

	// ip link set <iface> up
	if err := execCommand("ip", "link", "set", t.tunName, "up"); err != nil {
		return fmt.Errorf("ip link set up: %w", err)
	}

	// DNS — не трогаем /etc/resolv.conf напрямую.
	// Пользователь сам решит, куда его направить.
	_ = tunDNS

	return nil
}

// Cleanup снимает интерфейс и закрывает всё, что открыто.
func (t *TunBridge) Cleanup() {
	t.mu.Lock()
	if !t.running {
		t.mu.Unlock()
		return
	}
	t.running = false
	t.mu.Unlock()

	close(t.stopCh)

	if t.udp != nil {
		t.udp.Close()
	}
	if t.iface != nil {
		t.iface.Close()
	}

	// ip link del <iface>
	_ = execCommand("ip", "link", "del", t.tunName)
}

func isTimeout(err error) bool {
	if err == nil {
		return false
	}
	ne, ok := err.(net.Error)
	return ok && ne.Timeout()
}
