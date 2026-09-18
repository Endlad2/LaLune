// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// smarttunnel.go — встроенный Lua 5.1-рантайм для SmartTunnel.
//
// Использует github.com/yuin/gopher-lua (совместим с Lua 5.1).
//
// Скрипт встраивается через go:embed. Запускается один раз при старте,
// если в settings.json включён флаг enableSmartTunnel.
//
// API, доступное из Lua (глобальная таблица smarttunnel):
//   smarttunnel.log(message)
//   smarttunnel.logs()
//   smarttunnel.connect()
//   smarttunnel.disconnect()
//   smarttunnel.is_connected()
//   smarttunnel.set_args(table)
//   smarttunnel.get_args()
//   smarttunnel.get_vk_creds()
//   smarttunnel.get_setting(key)
//   smarttunnel.set_setting(key, value)

package libs

import (
	"embed"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	lua "github.com/yuin/gopher-lua"
)

//go:embed SmartTunnel.lua
var smartTunnelFS embed.FS

const (
	smartTunnelTickInterval = 1 * time.Second
	smartTunnelLogLimit     = 500
)

// SmartTunnel — обёртка над Lua-рантаймом.
type SmartTunnel struct {
	core *AppCore
	mu   sync.Mutex

	state *lua.LState

	// Буфер логов, которые читает Lua через smarttunnel.logs().
	logs   []string
	logsMu sync.Mutex

	// Аргументы cmd для ядра. Могут быть переопределены из Lua.
	args   []string
	argsMu sync.Mutex

	running  bool
	stopChan chan struct{}
}

// NewSmartTunnel создаёт рантайм, но не запускает скрипт.
func NewSmartTunnel(core *AppCore) *SmartTunnel {
	return &SmartTunnel{
		core:     core,
		stopChan: make(chan struct{}),
	}
}

// Start загружает SmartTunnel.lua и запускает его.
// Если уже запущен — ничего не делает.
func (st *SmartTunnel) Start() error {
	st.mu.Lock()
	if st.running {
		st.mu.Unlock()
		return nil
	}
	st.mu.Unlock()

	L := lua.NewState(lua.Options{
		SkipOpenLibs: false,
	})
	st.state = L

	// Регистрируем глобальную таблицу `smarttunnel`.
	st.registerAPI(L)

	// Читаем встроенный .lua.
	src, err := smartTunnelFS.ReadFile("SmartTunnel.lua")
	if err != nil {
		L.Close()
		st.state = nil
		return fmt.Errorf("не удалось прочитать SmartTunnel.lua: %w", err)
	}

	// Загружаем скрипт.
	if err := L.DoString(string(src)); err != nil {
		L.Close()
		st.state = nil
		return fmt.Errorf("ошибка загрузки SmartTunnel.lua: %w", err)
	}

	// Вызываем on_load(), если он есть.
	st.callIfExists("on_load")

	st.mu.Lock()
	st.running = true
	st.stopChan = make(chan struct{})
	stopChan := st.stopChan
	st.mu.Unlock()

	// Тикаем раз в секунду.
	go st.tickLoop(stopChan)

	st.core.AddLog("[SMART-TUNNEL] Рантайм запущен")
	return nil
}

// Stop останавливает Lua-рантайм.
func (st *SmartTunnel) Stop() {
	st.mu.Lock()
	if !st.running {
		st.mu.Unlock()
		return
	}
	st.running = false
	close(st.stopChan)
	L := st.state
	st.state = nil
	st.mu.Unlock()

	if L != nil {
		L.Close()
	}
	st.core.AddLog("[SMART-TUNNEL] Рантайм остановлен")
}

// IsRunning — true, если скрипт активен.
func (st *SmartTunnel) IsRunning() bool {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.running
}

// tickLoop вызывает on_tick() раз в секунду.
func (st *SmartTunnel) tickLoop(stop <-chan struct{}) {
	ticker := time.NewTicker(smartTunnelTickInterval)
	defer ticker.Stop()

	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			st.callIfExists("on_tick")
		}
	}
}

// callIfExists вызывает глобальную функцию по имени, если она определена.
func (st *SmartTunnel) callIfExists(name string) {
	st.mu.Lock()
	L := st.state
	st.mu.Unlock()
	if L == nil {
		return
	}
	fn := L.GetGlobal(name)
	if fn.Type() != lua.LTFunction {
		return
	}
	if err := L.CallByParam(lua.P{
		Fn:      fn,
		NRet:    0,
		Protect: true,
	}); err != nil {
		st.core.AddLog(fmt.Sprintf("[SMART-TUNNEL] Ошибка в %s: %v", name, err))
	}
}

// registerAPI регистрирует таблицу `smarttunnel`.
func (st *SmartTunnel) registerAPI(L *lua.LState) {
	mod := L.NewTable()
	L.SetGlobal("smarttunnel", mod)

	// --- smarttunnel.log(message) ---
	L.SetField(mod, "log", L.NewFunction(func(L *lua.LState) int {
		msg := L.CheckString(1)
		st.appendLog(msg)
		st.core.AddLog(msg)
		return 0
	}))

	// --- smarttunnel.logs() → table of strings ---
	L.SetField(mod, "logs", L.NewFunction(func(L *lua.LState) int {
		st.logsMu.Lock()
		snapshot := append([]string{}, st.logs...)
		st.logsMu.Unlock()

		tbl := L.NewTable()
		for i, line := range snapshot {
			tbl.RawSetInt(i+1, lua.LString(line))
		}
		L.Push(tbl)
		return 1
	}))

	// --- smarttunnel.connect() ---
	L.SetField(mod, "connect", L.NewFunction(func(L *lua.LState) int {
		st.core.AddLog("[SMART-TUNNEL] connect() — пока не реализовано")
		L.Push(lua.LFalse)
		return 1
	}))

	// --- smarttunnel.disconnect() ---
	L.SetField(mod, "disconnect", L.NewFunction(func(L *lua.LState) int {
		st.core.AddLog("[SMART-TUNNEL] disconnect() — пока не реализовано")
		L.Push(lua.LFalse)
		return 1
	}))

	// --- smarttunnel.is_connected() ---
	L.SetField(mod, "is_connected", L.NewFunction(func(L *lua.LState) int {
		L.Push(lua.LBool(st.core.IsConnected()))
		return 1
	}))

	// --- smarttunnel.set_args(table) ---
	L.SetField(mod, "set_args", L.NewFunction(func(L *lua.LState) int {
		tbl := L.CheckTable(1)
		var args []string
		tbl.ForEach(func(_, v lua.LValue) {
			if s, ok := v.(lua.LString); ok {
				args = append(args, string(s))
			}
		})
		st.argsMu.Lock()
		st.args = args
		st.argsMu.Unlock()
		return 0
	}))

	// --- smarttunnel.get_args() → table ---
	L.SetField(mod, "get_args", L.NewFunction(func(L *lua.LState) int {
		st.argsMu.Lock()
		snapshot := append([]string{}, st.args...)
		st.argsMu.Unlock()

		tbl := L.NewTable()
		for i, a := range snapshot {
			tbl.RawSetInt(i+1, lua.LString(a))
		}
		L.Push(tbl)
		return 1
	}))

	// --- smarttunnel.get_vk_creds() → table { token, hashes, userId, expiresIn } ---
	L.SetField(mod, "get_vk_creds", L.NewFunction(func(L *lua.LState) int {
		tbl := L.NewTable()
		token := st.core.ReadTokenFromFile()
		L.SetField(tbl, "token", lua.LString(token))
		L.SetField(tbl, "hashes", lua.LString(""))
		L.SetField(tbl, "userId", lua.LString(""))
		L.SetField(tbl, "expiresIn", lua.LNumber(0))
		L.Push(tbl)
		return 1
	}))

	// --- smarttunnel.get_setting(key) → value ---
	L.SetField(mod, "get_setting", L.NewFunction(func(L *lua.LState) int {
		key := L.CheckString(1)
		val := st.core.smartTunnelGetSetting(key)
		L.Push(val)
		return 1
	}))

	// --- smarttunnel.set_setting(key, value) ---
	L.SetField(mod, "set_setting", L.NewFunction(func(L *lua.LState) int {
		key := L.CheckString(1)
		val := L.Get(2)
		st.core.smartTunnelSetSetting(key, val)
		return 0
	}))
}

// appendLog кладёт строку в локальный буфер (для smarttunnel.logs()).
func (st *SmartTunnel) appendLog(msg string) {
	st.logsMu.Lock()
	defer st.logsMu.Unlock()
	st.logs = append(st.logs, msg)
	if len(st.logs) > smartTunnelLogLimit {
		st.logs = st.logs[len(st.logs)-smartTunnelLogLimit:]
	}
}

// SetArgs — переопределяет аргументы cmd для ядра (вызывается извне, например из bridge).
func (st *SmartTunnel) SetArgs(args []string) {
	st.argsMu.Lock()
	defer st.argsMu.Unlock()
	st.args = args
}

// GetArgs — читает текущие аргументы.
func (st *SmartTunnel) GetArgs() []string {
	st.argsMu.Lock()
	defer st.argsMu.Unlock()
	return append([]string{}, st.args...)
}

// =====================================================================
//  Методы AppCore, вызываемые из Lua API
// =====================================================================

// smartTunnelGetSetting возвращает значение настройки по ключу.
func (a *AppCore) smartTunnelGetSetting(key string) lua.LValue {
	switch key {
	case "enableSmartTunnel":
		if a.settings.EnableSmartTunnel {
			return lua.LTrue
		}
		return lua.LFalse
	case "workers":
		return lua.LNumber(a.settings.Workers)
	case "autoApiWorkers":
		return lua.LNumber(a.settings.AutoApiWorkers)
	case "obfs":
		return lua.LString(a.settings.Obfs)
	case "fingerprint":
		return lua.LString(a.settings.Fingerprint)
	case "authMode":
		return lua.LString(a.settings.AuthMode)
	case "peer":
		return lua.LString(a.settings.Peer)
	default:
		return lua.LNil
	}
}

// smartTunnelSetSetting пишет настройку в память (не сохраняет в файл).
func (a *AppCore) smartTunnelSetSetting(key string, value lua.LValue) {
	switch key {
	case "enableSmartTunnel":
		if b, ok := value.(lua.LBool); ok {
			a.settings.EnableSmartTunnel = bool(b)
		}
	case "workers":
		if n, ok := value.(lua.LNumber); ok {
			a.settings.Workers = int(n)
		}
	case "autoApiWorkers":
		if n, ok := value.(lua.LNumber); ok {
			a.settings.AutoApiWorkers = int(n)
		}
	case "obfs":
		if s, ok := value.(lua.LString); ok {
			a.settings.Obfs = string(s)
		}
	case "fingerprint":
		if s, ok := value.(lua.LString); ok {
			a.settings.Fingerprint = string(s)
		}
	case "authMode":
		if s, ok := value.(lua.LString); ok {
			a.settings.AuthMode = string(s)
		}
	case "peer":
		if s, ok := value.(lua.LString); ok {
			a.settings.Peer = string(s)
		}
	}
}

// _ — избегаем unused-import для os и filepath.
var _ = os.Getenv
var _ = filepath.Join
var _ = strings.TrimSpace
