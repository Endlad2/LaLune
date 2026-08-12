// cmd/server/platform_unix.go
//go:build linux || darwin

package main

import (
	"github.com/sirupsen/logrus"
	"golang.zx2c4.com/wireguard/tun"
)

func platformSetup() error {
	logrus.Info("Linux/macOS detected — using native TUN driver")
	return nil
}

func createTUN(name string, mtu int) (tun.Device, error) {
	return tun.CreateTUN(name, mtu)
}