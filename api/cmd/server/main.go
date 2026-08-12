// cmd/server/main.go
package main

import (
	"archive/zip"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/mux"
	"github.com/sirupsen/logrus"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
)

var (
	wdttBinaryPath string
	wdttProcess    *os.Process
	wdttProcessMu  sync.Mutex
	configPath     string
	logFile        *os.File
	logMu          sync.Mutex
	wgDevice       *device.Device
	wgTun          tun.Device
	wgDeviceMu     sync.Mutex
	wgRunning      bool
)

const (
	apiPort = "7419"
	repoURL = "https://raw.githubusercontent.com/Endlad2/wdtt-rslib/refs/heads/main/LATEST.md"
	tempDir = "wdtt_temp"
)

func main() {
	logrus.SetFormatter(&logrus.TextFormatter{
		FullTimestamp: true,
	})

	logrus.Infof("Starting La Lune API Server on %s/%s...", runtime.GOOS, runtime.GOARCH)

	if err := platformSetup(); err != nil {
		logrus.Fatalf("Platform setup failed: %v", err)
	}

	if err := setupBinary(); err != nil {
		logrus.Fatalf("Failed to setup binary: %v", err)
	}

	r := mux.NewRouter()
	r.HandleFunc("/api/start", handleStart).Methods("GET")
	r.HandleFunc("/api/start-tunnel", handleStartTunnel).Methods("GET")
	r.HandleFunc("/api/connect", handleConnect).Methods("POST")
	r.HandleFunc("/api/logs", handleLogs).Methods("GET")
	r.HandleFunc("/api/logs/write", handleLogsWrite).Methods("GET", "POST")
	r.HandleFunc("/api/disconnect", handleDisconnect).Methods("GET")

	r.PathPrefix("/").Handler(http.FileServer(http.Dir("./web")))

	logrus.Infof("API Server listening on :%s", apiPort)
	if err := http.ListenAndServe(":"+apiPort, r); err != nil {
		logrus.Fatalf("Server failed: %v", err)
	}
}

func setupBinary() error {
	os.MkdirAll(tempDir, 0755)

	resp, err := http.Get(repoURL)
	if err != nil {
		return fmt.Errorf("failed to fetch LATEST.md: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("failed to read LATEST.md: %w", err)
	}

	baseURL := strings.TrimSpace(string(body))
	if baseURL == "" {
		return fmt.Errorf("empty URL from LATEST.md")
	}

	archiveName := getArchiveName()
	if archiveName == "" {
		return fmt.Errorf("unsupported platform: %s/%s", runtime.GOOS, runtime.GOARCH)
	}

	fullURL := baseURL + archiveName
	logrus.Infof("Downloading from: %s", fullURL)

	archivePath := filepath.Join(tempDir, archiveName)
	if err := downloadFile(fullURL, archivePath); err != nil {
		return fmt.Errorf("failed to download archive: %w", err)
	}

	if err := extractArchive(archivePath, tempDir); err != nil {
		return fmt.Errorf("failed to extract archive: %w", err)
	}

	wdttBinaryPath = filepath.Join(tempDir, "wdtt-client")
	if runtime.GOOS == "windows" {
		wdttBinaryPath += ".exe"
	}

	if _, err := os.Stat(wdttBinaryPath); os.IsNotExist(err) {
		return fmt.Errorf("binary not found after extraction")
	}

	if err := os.Chmod(wdttBinaryPath, 0755); err != nil {
		logrus.Warnf("Failed to chmod binary: %v", err)
	}

	logrus.Infof("Binary ready at: %s", wdttBinaryPath)
	return nil
}

func getArchiveName() string {
	goos := runtime.GOOS
	arch := runtime.GOARCH

	switch goos {
	case "linux":
		if arch == "amd64" {
			return "wdtt-client-linux-x86_64.zip"
		}
		return ""
	case "darwin":
		if arch == "arm64" {
			return "wdtt-client-macos-aarch64.zip"
		}
		if arch == "amd64" {
			return "wdtt-client-macos-x86_64.zip"
		}
		return ""
	case "windows":
		if arch == "386" {
			return "wdtt-client-windows-i686.zip"
		}
		if arch == "amd64" {
			return "wdtt-client-windows-x86_64.zip"
		}
		return ""
	default:
		return ""
	}
}

func downloadFile(url, dest string) error {
	resp, err := http.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("bad status: %s", resp.Status)
	}

	out, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, resp.Body)
	return err
}

func extractArchive(archivePath, destDir string) error {
	if strings.HasSuffix(archivePath, ".zip") {
		return extractZip(archivePath, destDir)
	}
	return fmt.Errorf("unsupported archive format")
}

func extractZip(zipPath, destDir string) error {
	reader, err := zip.OpenReader(zipPath)
	if err != nil {
		return fmt.Errorf("failed to open zip: %w", err)
	}
	defer reader.Close()

	for _, file := range reader.File {
		path := filepath.Join(destDir, file.Name)

		if !strings.HasPrefix(path, filepath.Clean(destDir)+string(os.PathSeparator)) {
			return fmt.Errorf("illegal file path: %s", path)
		}

		if file.FileInfo().IsDir() {
			os.MkdirAll(path, 0755)
			continue
		}

		os.MkdirAll(filepath.Dir(path), 0755)

		dstFile, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, file.Mode())
		if err != nil {
			return fmt.Errorf("failed to create file: %w", err)
		}

		srcFile, err := file.Open()
		if err != nil {
			dstFile.Close()
			return fmt.Errorf("failed to open zip entry: %w", err)
		}

		_, err = io.Copy(dstFile, srcFile)
		dstFile.Close()
		srcFile.Close()

		if err != nil {
			return fmt.Errorf("failed to extract file: %w", err)
		}
	}

	logrus.Infof("Extracted %d files from %s", len(reader.File), zipPath)
	return nil
}

func handleStart(w http.ResponseWriter, r *http.Request) {
	peer := r.URL.Query().Get("peer")
	vk := r.URL.Query().Get("vk")
	n := r.URL.Query().Get("n")
	listen := r.URL.Query().Get("listen")

	if peer == "" || vk == "" || n == "" || listen == "" {
		http.Error(w, "Missing required parameters: peer, vk, n, listen", http.StatusBadRequest)
		return
	}

	nInt, err := strconv.Atoi(n)
	if err != nil || nInt < 9 || nInt > 109 {
		http.Error(w, "n must be between 9 and 109", http.StatusBadRequest)
		return
	}

	vkParts := strings.Split(vk, ",")
	if len(vkParts) < 1 || len(vkParts) > 4 {
		http.Error(w, "vk must contain 1-4 hashes", http.StatusBadRequest)
		return
	}

	wdttProcessMu.Lock()
	defer wdttProcessMu.Unlock()

	if wdttProcess != nil {
		if err := wdttProcess.Kill(); err != nil {
			logrus.Warnf("Failed to kill existing process: %v", err)
		}
		wdttProcess = nil
	}

	args := []string{
		"-peer", peer,
		"-vk", vk,
		"-n", n,
		"-listen", listen,
	}

	cmd := exec.Command(wdttBinaryPath, args...)

	if logFile != nil {
		logFile.Close()
	}
	logPath := filepath.Join(tempDir, fmt.Sprintf("wdtt_%d.log", time.Now().Unix()))
	logFile, err = os.Create(logPath)
	if err != nil {
		http.Error(w, "Failed to create log file", http.StatusInternalServerError)
		return
	}

	cmd.Stdout = logFile
	cmd.Stderr = logFile

	if err := cmd.Start(); err != nil {
		logrus.Errorf("Failed to start WDTT: %v", err)
		http.Error(w, "Failed to start WDTT", http.StatusInternalServerError)
		return
	}

	wdttProcess = cmd.Process
	logrus.Infof("WDTT started with PID: %d", wdttProcess.Pid)

	configPath = findConfigFile()
	if configPath == "" {
		logrus.Warn("Config file not found after start")
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status": "started",
		"pid":    strconv.Itoa(wdttProcess.Pid),
		"config": configPath,
	})
}

func findConfigFile() string {
	searchDirs := []string{
		".",
		tempDir,
	}

	for _, dir := range searchDirs {
		cfgPath := filepath.Join(dir, "config.toml")
		if _, err := os.Stat(cfgPath); err == nil {
			abs, _ := filepath.Abs(cfgPath)
			return abs
		}
	}
	return ""
}

func handleConnect(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Only POST allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "Failed to read body", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	var req struct {
		ConfigBase64 string `json:"config_base64"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "Invalid JSON: "+err.Error(), http.StatusBadRequest)
		return
	}

	if req.ConfigBase64 == "" {
		http.Error(w, "config_base64 is required", http.StatusBadRequest)
		return
	}

	configData, err := base64.StdEncoding.DecodeString(req.ConfigBase64)
	if err != nil {
		http.Error(w, "Invalid base64: "+err.Error(), http.StatusBadRequest)
		return
	}

	configPath := filepath.Join(tempDir, fmt.Sprintf("wg_config_%d.conf", time.Now().Unix()))
	if err := os.WriteFile(configPath, configData, 0600); err != nil {
		http.Error(w, "Failed to write config file: "+err.Error(), http.StatusInternalServerError)
		return
	}

	logrus.Infof("Config saved to: %s", configPath)

	wgDeviceMu.Lock()
	defer wgDeviceMu.Unlock()

	if wgRunning {
		if err := stopWireGuard(); err != nil {
			logrus.Warnf("Failed to stop existing WireGuard: %v", err)
		}
	}

	tunDev, err := createTUN("wg0", 1420)
	if err != nil {
		http.Error(w, fmt.Sprintf("Failed to create TUN device: %v", err), http.StatusInternalServerError)
		return
	}
	wgTun = tunDev

	wgDev := device.NewDevice(tunDev, nil, nil)
	wgDevice = wgDev

	if err := wgDev.IpcSet(string(configData)); err != nil {
		http.Error(w, fmt.Sprintf("Failed to apply config: %v", err), http.StatusInternalServerError)
		return
	}

	if err := wgDev.Up(); err != nil {
		http.Error(w, fmt.Sprintf("Failed to bring up interface: %v", err), http.StatusInternalServerError)
		return
	}

	wgRunning = true
	logrus.Info("Tunnel established via /api/connect")

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":      "connected",
		"config_path": configPath,
	})
}

func handleStartTunnel(w http.ResponseWriter, r *http.Request) {
	configFile := r.URL.Query().Get("config_file")
	if configFile == "" {
		http.Error(w, "config_file parameter required", http.StatusBadRequest)
		return
	}

	if _, err := os.Stat(configFile); os.IsNotExist(err) {
		http.Error(w, "Config file does not exist", http.StatusBadRequest)
		return
	}

	wgDeviceMu.Lock()
	defer wgDeviceMu.Unlock()

	if wgRunning {
		if err := stopWireGuard(); err != nil {
			logrus.Warnf("Failed to stop existing WireGuard: %v", err)
		}
	}

	tunDev, err := createTUN("wg0", 1420)
	if err != nil {
		http.Error(w, fmt.Sprintf("Failed to create TUN device: %v", err), http.StatusInternalServerError)
		return
	}
	wgTun = tunDev

	wgDev := device.NewDevice(tunDev, nil, nil)
	wgDevice = wgDev

	configData, err := os.ReadFile(configFile)
	if err != nil {
		http.Error(w, "Failed to read config file", http.StatusInternalServerError)
		return
	}

	if err := wgDev.IpcSet(string(configData)); err != nil {
		http.Error(w, fmt.Sprintf("Failed to apply config: %v", err), http.StatusInternalServerError)
		return
	}

	if err := wgDev.Up(); err != nil {
		http.Error(w, fmt.Sprintf("Failed to bring up interface: %v", err), http.StatusInternalServerError)
		return
	}

	wgRunning = true
	logrus.Infof("Tunnel started with config: %s", configFile)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status": "tunnel_established",
		"config": configFile,
	})
}

func stopWireGuard() error {
	if wgDevice != nil {
		wgDevice.Close()
		wgDevice = nil
	}
	if wgTun != nil {
		wgTun.Close()
		wgTun = nil
	}
	wgRunning = false
	return nil
}

func handleLogs(w http.ResponseWriter, r *http.Request) {
	logMu.Lock()
	defer logMu.Unlock()

	if logFile == nil {
		http.Error(w, "No log file available", http.StatusNotFound)
		return
	}

	if err := logFile.Sync(); err != nil {
		logrus.Warnf("Failed to sync log file: %v", err)
	}

	data, err := os.ReadFile(logFile.Name())
	if err != nil {
		http.Error(w, "Failed to read log file", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain")
	w.Write(data)
}

func handleLogsWrite(w http.ResponseWriter, r *http.Request) {
	text := r.URL.Query().Get("text")
	base64Text := r.URL.Query().Get("base64")

	if text == "" && base64Text == "" {
		http.Error(w, "text or base64 parameter required", http.StatusBadRequest)
		return
	}

	logMu.Lock()
	defer logMu.Unlock()

	if logFile == nil {
		http.Error(w, "No log file available", http.StatusNotFound)
		return
	}

	var content string
	if base64Text != "" {
		content = base64Text
	} else {
		content = text
	}

	timestamp := time.Now().Format("2006-01-02 15:04:05")
	entry := fmt.Sprintf("[%s] %s\n", timestamp, content)

	if _, err := logFile.WriteString(entry); err != nil {
		http.Error(w, "Failed to write log", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status": "logged",
	})
}

func handleDisconnect(w http.ResponseWriter, r *http.Request) {
	wdttProcessMu.Lock()
	defer wdttProcessMu.Unlock()

	if wdttProcess != nil {
		if err := wdttProcess.Kill(); err != nil {
			logrus.Warnf("Failed to kill process: %v", err)
		}
		wdttProcess = nil
		logrus.Info("WDTT process killed")
	}

	wgDeviceMu.Lock()
	defer wgDeviceMu.Unlock()

	if wgRunning {
		if err := stopWireGuard(); err != nil {
			logrus.Warnf("Failed to stop WireGuard: %v", err)
		} else {
			logrus.Info("WireGuard stopped")
		}
	}

	if configPath != "" {
		if err := os.Remove(configPath); err != nil {
			logrus.Warnf("Failed to remove config file: %v", err)
		} else {
			logrus.Infof("Config file removed: %s", configPath)
			configPath = ""
		}
	}

	if logFile != nil {
		logFile.Close()
		logFile = nil
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status": "disconnected",
	})
}
