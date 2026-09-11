package main

import (
	"encoding/json"
	"fmt"
	"os"
)

// Простой CLI для ubus-скрипта: lalune <cmd> [args]
//
//   lalune status                     — напечатать status.json
//   lalune version                    — напечатать версию ядра (local/remote)
//   lalune core-check                 — проверить наличие обновления ядра (без скачивания)
//   lalune core-update                — скачать обновление ядра
//   lalune connect <config_id>        — подключиться к сохранённому конфигу
//   lalune disconnect                 — отключиться
//   lalune config-list                — список конфигов
//   lalune config-add <link>          — добавить конфиг из csqtt:// ссылки
//   lalune config-delete <id>         — удалить конфиг
//   lalune settings-get               — текущие настройки
//   lalune settings-set <json>        — сохранить настройки
//   lalune device-id                  — текущий deviceId
//   lalune device-id-regenerate       — перегенерировать deviceId
//   lalune lalune-check               — проверить обновление LaLune (заглушка)
//
// Команды connect/disconnect/core-update работают через локальный сокет
// к уже запущенному демону (см. ipc.go). Если демон не запущен — печатают ошибку.
func runCLI(args []string) {
	if len(args) == 0 {
		printUsage()
		os.Exit(1)
	}

	cmd := args[0]
	rest := args[1:]

	switch cmd {
	case "status":
		statusCmd()
	case "version":
		versionCmd()
	case "core-check":
		coreCheckCmd()
	case "core-update":
		coreUpdateCmd()
	case "connect":
		requireArg(rest, "connect <config_id>")
		ipcCall("connect", map[string]string{"config_id": rest[0]})
	case "disconnect":
		ipcCall("disconnect", nil)
	case "config-list":
		configListCmd()
	case "config-add":
		requireArg(rest, "config-add <link>")
		configAddCmd(rest[0])
	case "config-delete":
		requireArg(rest, "config-delete <id>")
		configDeleteCmd(rest[0])
	case "settings-get":
		settingsGetCmd()
	case "settings-set":
		requireArg(rest, "settings-set <json>")
		settingsSetCmd(rest[0])
	case "device-id":
		deviceIDCmd(false)
	case "device-id-regenerate":
		deviceIDCmd(true)
	case "lalune-check":
		laluneCheckCmd()
	default:
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Fprintln(os.Stderr, `lalune — CLI клиента LaLune для OpenWRT

  lalune status
  lalune version
  lalune core-check
  lalune core-update
  lalune connect <config_id>
  lalune disconnect
  lalune config-list
  lalune config-add <csqtt://...>
  lalune config-delete <id>
  lalune settings-get
  lalune settings-set '<json>'
  lalune device-id
  lalune device-id-regenerate
  lalune lalune-check`)
}

func requireArg(args []string, usage string) {
	if len(args) < 1 {
		fmt.Fprintf(os.Stderr, "usage: lalune %s\n", usage)
		os.Exit(1)
	}
}

func statusCmd() {
	data, err := os.ReadFile(StatusFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, `{"error":"status.json not found"}`)
		os.Exit(1)
	}
	fmt.Print(string(data))
}

func versionCmd() {
	data, _ := VersionFileToJSON()
	fmt.Println(string(data))
}

func coreCheckCmd() {
	remote, local, hasUpdate, err := CheckForUpdate()
	out := map[string]interface{}{
		"remote":     remote,
		"local":      local,
		"hasUpdate":  hasUpdate,
	}
	if err != nil {
		out["error"] = err.Error()
	}
	enc, _ := json.MarshalIndent(out, "", "  ")
	fmt.Println(string(enc))
}

func coreUpdateCmd() {
	arch := ArchFromRuntime()
	if err := DownloadCore(arch); err != nil {
		fmt.Fprintf(os.Stderr, `{"ok":false,"error":%q}`+"\n", err.Error())
		os.Exit(1)
	}
	fmt.Printf(`{"ok":true,"version":%q}`+"\n", LocalVersion())
}

func configListCmd() {
	store, err := NewConfigStore()
	if err != nil {
		fmt.Fprintf(os.Stderr, `{"error":%q}`+"\n", err.Error())
		os.Exit(1)
	}
	data, _ := json.MarshalIndent(store.GetConfigs(), "", "  ")
	fmt.Println(string(data))
}

func configAddCmd(link string) {
	store, err := NewConfigStore()
	if err != nil {
		fmt.Fprintf(os.Stderr, `{"error":%q}`+"\n", err.Error())
		os.Exit(1)
	}
	cfg := ParseCsqttLink(link)
	if err := store.AddConfig(cfg); err != nil {
		fmt.Fprintf(os.Stderr, `{"error":%q}`+"\n", err.Error())
		os.Exit(1)
	}
	fmt.Println(`{"ok":true}`)
}

func configDeleteCmd(idStr string) {
	store, err := NewConfigStore()
	if err != nil {
		fmt.Fprintf(os.Stderr, `{"error":%q}`+"\n", err.Error())
		os.Exit(1)
	}
	var id int64
	fmt.Sscanf(idStr, "%d", &id)
	if err := store.DeleteConfig(id); err != nil {
		fmt.Fprintf(os.Stderr, `{"error":%q}`+"\n", err.Error())
		os.Exit(1)
	}
	fmt.Println(`{"ok":true}`)
}

func settingsGetCmd() {
	store, err := NewConfigStore()
	if err != nil {
		fmt.Fprintf(os.Stderr, `{"error":%q}`+"\n", err.Error())
		os.Exit(1)
	}
	data, _ := json.MarshalIndent(store.GetSettings(), "", "  ")
	fmt.Println(string(data))
}

func settingsSetCmd(jsonStr string) {
	store, err := NewConfigStore()
	if err != nil {
		fmt.Fprintf(os.Stderr, `{"error":%q}`+"\n", err.Error())
		os.Exit(1)
	}
	var s Settings
	if err := json.Unmarshal([]byte(jsonStr), &s); err != nil {
		fmt.Fprintf(os.Stderr, `{"error":%q}`+"\n", err.Error())
		os.Exit(1)
	}
	if err := store.SetSettings(s); err != nil {
		fmt.Fprintf(os.Stderr, `{"error":%q}`+"\n", err.Error())
		os.Exit(1)
	}
	fmt.Println(`{"ok":true}`)
}

func deviceIDCmd(regenerate bool) {
	store, err := NewConfigStore()
	if err != nil {
		fmt.Fprintf(os.Stderr, `{"error":%q}`+"\n", err.Error())
		os.Exit(1)
	}
	if regenerate {
		id := store.RegenerateDeviceID()
		fmt.Printf(`{"deviceId":%q}`+"\n", id)
		return
	}
	fmt.Printf(`{"deviceId":%q}`+"\n", store.GetSettings().DeviceId)
}

func laluneCheckCmd() {
	local, remote, hasUpdate := CheckLaLuneUpdate()
	out := map[string]interface{}{
		"local":     local,
		"remote":    remote,
		"hasUpdate": hasUpdate,
	}
	enc, _ := json.MarshalIndent(out, "", "  ")
	fmt.Println(string(enc))
}
