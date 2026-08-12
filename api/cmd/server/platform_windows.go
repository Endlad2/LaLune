// cmd/server/platform_windows.go
//go:build windows

package main

import (
	_ "embed"
	"fmt"
	"os"
	"path/filepath"

	"github.com/sirupsen/logrus"
	"golang.zx2c4.com/wireguard/tun"
)

//go:embed wintun.dll
var wintunDLL []byte

var _ = wintunDLL

func init() {
	if len(wintunDLL) == 0 {
		panic("wintun.dll is empty — embed failed")
	}
}

func platformSetup() error {
	logrus.Info("Windows detected — extracting wintun.dll...")
	return extractWintun()
}

func extractWintun() error {
	exePath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("failed to get executable path: %w", err)
	}
	exeDir := filepath.Dir(exePath)
	dllPath := filepath.Join(exeDir, "wintun.dll")

	if existingData, err := os.ReadFile(dllPath); err == nil {
		if len(existingData) == len(wintunDLL) {
			logrus.Info("wintun.dll already exists with correct size")
			return nil
		}
		logrus.Info("wintun.dll exists but size mismatch, overwriting...")
	}

	logrus.Infof("Extracting wintun.dll from embedded data (%d bytes)...", len(wintunDLL))
	if err := os.WriteFile(dllPath, wintunDLL, 0644); err != nil {
		return fmt.Errorf("failed to write wintun.dll: %w", err)
	}

	logrus.Infof("wintun.dll extracted to: %s", dllPath)
	return nil
}

func createTUN(name string, mtu int) (tun.Device, error) {
	return tun.CreateTUN(name, mtu)
}