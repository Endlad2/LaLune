package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	// Если запущено с аргументами — это CLI-режим.
	if len(os.Args) > 1 {
		runCLI(os.Args[1:])
		return
	}

	// Иначе — демон.
	runDaemon()
}

func runDaemon() {
	// Логи в файл и stderr (procd подхватит stderr в свой лог).
	logFile, err := os.OpenFile(LogFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		log.Fatalf("open logfile: %v", err)
	}
	defer logFile.Close()
	log.SetOutput(logFile)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	log.Printf("=== LaLune OpenWRT daemon starting ===")

	arch := ArchFromRuntime()
	log.Printf("Architecture: %s, core file: %s", arch, CoreFilename(arch))

	store, err := NewConfigStore()
	if err != nil {
		log.Fatalf("config store: %v", err)
	}
	globalStore = store

	ensureCoreAtStartup()

	state := &State{LastStatusUpdate: time.Now().Unix()}
	state.CoreVersion = LocalVersion()
	WriteStatus(state)

	coreMgr := NewCoreManager(store, arch, state)

	// IPC-сервер для CLI
	if err := StartIPCServer(func(method string, args map[string]string) (string, error) {
		return ipcHandler(coreMgr, store, method, args)
	}); err != nil {
		log.Printf("IPC server: %v", err)
	}

	// Первичная запись статуса и обновление раз в 5 секунд,
	// чтобы LuCI всегда видел актуальный UpdateAvailable.
	go func() {
		t := time.NewTicker(5 * time.Second)
		defer t.Stop()
		for range t.C {
			WriteStatus(state)
		}
	}()

	// Auto-connect, если включён в settings и есть хотя бы один конфиг
	if store.GetSettings().AutoConnect {
		cfgs := store.GetConfigs()
		if len(cfgs) > 0 {
			log.Printf("[AUTO] autoConnect=true, стартую с первым конфигом id=%d", cfgs[0].ID)
			if err := coreMgr.Start(cfgs[0], store.GetSettings()); err != nil {
				log.Printf("[AUTO] ошибка авто-подключения: %v", err)
			}
		}
	}

	// Ждём SIGINT/SIGTERM
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigCh
	log.Printf("received signal %v, shutting down", sig)

	_ = coreMgr.Stop()
	WriteStatus(state)
	log.Printf("=== LaLune OpenWRT daemon stopped ===")
}

// ipcHandler — обработчик команд от CLI.
func ipcHandler(mgr *CoreManager, store *ConfigStore, method string, args map[string]string) (string, error) {
	switch method {
	case "connect":
		idStr := args["config_id"]
		var id int64
		fmt.Sscanf(idStr, "%d", &id)
		cfg := store.GetConfigByID(id)
		if cfg == nil {
			return "", fmt.Errorf("config id=%d not found", id)
		}
		if err := mgr.Start(*cfg, store.GetSettings()); err != nil {
			return "", err
		}
		return `{"ok":true}`, nil

	case "disconnect":
		if err := mgr.Stop(); err != nil {
			return "", err
		}
		return `{"ok":true}`, nil

	case "reload":
		// Перечитать настройки из файла (после settings-set)
		// Пока просто возвращаем ok, т.к. store уже пишет в файл.
		return `{"ok":true}`, nil

	case "status":
		data, _ := json.MarshalIndent(map[string]interface{}{
			"connected": mgr.IsRunning(),
		}, "", "  ")
		return string(data), nil

	default:
		return "", fmt.Errorf("unknown IPC method: %s", method)
	}
}
