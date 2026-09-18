// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// capi.go — C-ABI обёртка над AppCore для Flutter Desktop (dart:ffi).
//
// ВАЖНО: этот файл лежит в cmd/ — рядом с main.go, потому что
// `go build ./cmd` компилирует ТОЛЬКО пакеты из этой директории.
// Файлы из родительской папки (Desktop/Libs/) в сборку не попадают,
// даже если у них тот же `package main`. Это и было причиной
// "Failed to lookup symbol 'lalune_init'": функция не экспортировалась,
// потому что не компилировалась.
//
// Собирается через: go build -buildmode=c-shared -o build/lalune.dll ./cmd
//
// Все функции возвращают char* (C-строка, JSON или простое значение).
// Dart читает через .cast<Utf8>().toDartString(), после чего обязан
// вызвать lalune_free(ptr) — иначе утечка.

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"sync"
	"unsafe"

	libs "lalune-libs"
)

// Глобальный экземпляр AppCore. Создаётся один раз при lalune_init().
var (
	globalCore *libs.AppCore
	coreMu     sync.Mutex
)

// ============================================================
//  Память
// ============================================================

//export lalune_free
func lalune_free(ptr *C.char) {
	if ptr != nil {
		C.free(unsafe.Pointer(ptr))
	}
}

// cstr возвращает C-строку из Go-строки. Dart обязан освободить через lalune_free.
func cstr(s string) *C.char {
	return C.CString(s)
}

// ============================================================
//  Init / Shutdown
// ============================================================

//export lalune_init
func lalune_init() C.int {
	coreMu.Lock()
	defer coreMu.Unlock()

	if globalCore != nil {
		return 0
	}

	core := libs.NewAppCore()
	core.Startup(nil)

	if err := libs.BuildBridge(core); err != nil {
		core.AddLog("[CAPI] Не удалось создать Bridge: " + err.Error())
	}

	globalCore = core
	return 0
}

//export lalune_shutdown
func lalune_shutdown() {
	coreMu.Lock()
	defer coreMu.Unlock()

	if globalCore != nil {
		if st := globalCore.GetSmartTunnel(); st != nil {
			st.Stop()
		}
	}
	globalCore = nil
}

// ============================================================
//  Configs
// ============================================================

//export lalune_get_configs_json
func lalune_get_configs_json() *C.char {
	core := currentCore()
	if core == nil {
		return cstr("[]")
	}
	return cstr(core.GetConfigsJson())
}

//export lalune_save_config
func lalune_save_config(link *C.char) C.int {
	core := currentCore()
	if core == nil {
		return 0
	}
	if core.SaveConfig(C.GoString(link)) {
		return 1
	}
	return 0
}

//export lalune_delete_config
func lalune_delete_config(id C.longlong) C.int {
	core := currentCore()
	if core == nil {
		return 0
	}
	if core.DeleteConfig(int64(id)) {
		return 1
	}
	return 0
}

// ============================================================
//  Settings
// ============================================================

//export lalune_get_settings_json
func lalune_get_settings_json() *C.char {
	core := currentCore()
	if core == nil {
		return cstr("{}")
	}
	return cstr(core.GetSettingsJson())
}

//export lalune_save_settings
func lalune_save_settings(settingsJson *C.char) C.int {
	core := currentCore()
	if core == nil {
		return 0
	}
	if core.SaveSettings(C.GoString(settingsJson)) {
		return 1
	}
	return 0
}

// ============================================================
//  Logs / Status
// ============================================================

//export lalune_get_logs_json
func lalune_get_logs_json() *C.char {
	core := currentCore()
	if core == nil {
		return cstr("[]")
	}
	return cstr(core.GetLogsJson())
}

//export lalune_clear_logs
func lalune_clear_logs() C.int {
	core := currentCore()
	if core == nil {
		return 0
	}
	if core.ClearLogs() {
		return 1
	}
	return 0
}

//export lalune_get_status_json
func lalune_get_status_json() *C.char {
	core := currentCore()
	if core == nil {
		return cstr(`{"connected":false}`)
	}
	return cstr(`{"connected":` + boolToStr(core.IsConnected()) + `}`)
}

// ============================================================
//  Connect / Disconnect
// ============================================================

//export lalune_connect
func lalune_connect(id C.longlong) C.int {
	core := currentCore()
	if core == nil {
		return 0
	}
	if core.ConnectViaBridge(int64(id)) {
		return 1
	}
	return 0
}

//export lalune_disconnect
func lalune_disconnect() C.int {
	core := currentCore()
	if core == nil {
		return 0
	}
	if core.DisconnectViaBridge() {
		return 1
	}
	return 0
}

// ============================================================
//  Selected config
// ============================================================

//export lalune_get_selected_config_json
func lalune_get_selected_config_json() *C.char {
	core := currentCore()
	if core == nil {
		return cstr("{}")
	}
	return cstr(core.GetSelectedConfigJson())
}

//export lalune_set_selected_config_json
func lalune_set_selected_config_json(jsonStr *C.char) C.int {
	core := currentCore()
	if core == nil {
		return 0
	}
	if core.SetSelectedConfigJson(C.GoString(jsonStr)) {
		return 1
	}
	return 0
}

// ============================================================
//  Core downloading
// ============================================================

//export lalune_is_core_downloading
func lalune_is_core_downloading() C.int {
	core := currentCore()
	if core == nil {
		return 0
	}
	if core.IsCoreDownloading() {
		return 1
	}
	return 0
}

// ============================================================
//  Core update
// ============================================================

//export lalune_check_core_update
func lalune_check_core_update() *C.char {
	core := currentCore()
	if core == nil {
		return cstr(`{"update":false,"version":""}`)
	}
	version, hasUpdate, err := core.CheckUpdateSync()
	if err != nil {
		return cstr(`{"error":` + jsonEscape(err.Error()) + `}`)
	}
	return cstr(`{"update":` + boolToStr(hasUpdate) + `,"version":` + jsonEscape(version) + `}`)
}

//export lalune_update_core
func lalune_update_core() C.int {
	core := currentCore()
	if core == nil {
		return 0
	}
	if core.UpdateCore() {
		return 1
	}
	return 0
}

//export lalune_update_core_and_wait
func lalune_update_core_and_wait() C.int {
	core := currentCore()
	if core == nil {
		return 0
	}
	if core.UpdateCoreAndWaitSync() {
		return 1
	}
	return 0
}

// ============================================================
//  LaLune update
// ============================================================

//export lalune_check_lalune_update
func lalune_check_lalune_update() *C.char {
	core := currentCore()
	if core == nil {
		return cstr(`{"update":false,"version":""}`)
	}
	result := core.CheckLaLuneUpdate()
	data, _ := json.Marshal(result)
	return cstr(string(data))
}

//export lalune_open_lalune_releases
func lalune_open_lalune_releases() *C.char {
	core := currentCore()
	if core == nil {
		return cstr("")
	}
	return cstr(core.OpenLaLuneReleasesURL())
}

// ============================================================
//  VK авторизация
// ============================================================

//export lalune_get_vk_token_state
func lalune_get_vk_token_state() *C.char {
	core := currentCore()
	if core == nil {
		return cstr(`{"hasToken":false,"fetcherOk":false,"fetching":false,"message":"","progress":0}`)
	}
	state := core.GetVKTokenState()
	data, _ := json.Marshal(state)
	return cstr(string(data))
}

//export lalune_validate_vk_token
func lalune_validate_vk_token() *C.char {
	core := currentCore()
	if core == nil {
		return cstr(`{"hasToken":false,"fetcherOk":false,"fetching":false,"message":"","progress":0}`)
	}
	state := core.ValidateVKToken()
	data, _ := json.Marshal(state)
	return cstr(string(data))
}

//export lalune_vk_login
func lalune_vk_login() C.int {
	core := currentCore()
	if core == nil {
		return 0
	}
	if core.LoginVK() {
		return 1
	}
	return 0
}

//export lalune_delete_vk_token
func lalune_delete_vk_token() C.int {
	core := currentCore()
	if core == nil {
		return 0
	}
	if core.DeleteVKToken() {
		return 1
	}
	return 0
}

// ============================================================
//  VK Auto API
// ============================================================

//export lalune_run_vk_auto_api_calls
func lalune_run_vk_auto_api_calls() *C.char {
	core := currentCore()
	if core == nil {
		return cstr(`{"error":"core not initialized"}`)
	}
	hashes, callIds, err := core.RunVkAutoApiCalls(func(s string) {
		core.AddLog(s)
	})
	if err != nil {
		return cstr(`{"error":` + jsonEscape(err.Error()) + `}`)
	}
	result := struct {
		Hashes  []string `json:"hashes"`
		CallIds []string `json:"callIds"`
	}{Hashes: hashes, CallIds: callIds}
	data, _ := json.Marshal(result)
	return cstr(string(data))
}

//export lalune_poll_auto_api_result
func lalune_poll_auto_api_result() *C.char {
	return cstr(`{"pending":false}`)
}

//export lalune_finish_vk_calls
func lalune_finish_vk_calls(callIdsJson *C.char) C.int {
	core := currentCore()
	if core == nil {
		return 0
	}
	var ids []string
	if err := json.Unmarshal([]byte(C.GoString(callIdsJson)), &ids); err != nil {
		return 0
	}
	core.FinishVkCalls(ids)
	return 1
}

// ============================================================
//  Device ID
// ============================================================

//export lalune_get_device_id
func lalune_get_device_id() *C.char {
	core := currentCore()
	if core == nil {
		return cstr("")
	}
	return cstr(core.GetSettings().DeviceId)
}

//export lalune_regenerate_device_id
func lalune_regenerate_device_id() *C.char {
	core := currentCore()
	if core == nil {
		return cstr("")
	}
	return cstr(core.RegenerateDeviceId())
}

// ============================================================
//  Helpers
// ============================================================

func currentCore() *libs.AppCore {
	coreMu.Lock()
	defer coreMu.Unlock()
	return globalCore
}

func boolToStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func jsonEscape(s string) string {
	data, _ := json.Marshal(s)
	return string(data)
}
