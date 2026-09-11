package main

import (
	"encoding/json"
	"sync"
)

// StatusSnapshot — то, что читает LuCI из /var/run/lalune/status.json.
type StatusSnapshot struct {
	Connected      bool   `json:"connected"`
	CoreVersion    string `json:"coreVersion"`    // установленная версия ("" если не скачано)
	RemoteVersion  string `json:"remoteVersion"`  // версия по LATEST
	UpdateAvailable bool  `json:"updateAvailable"`
	LastCoreError  string `json:"lastCoreError,omitempty"`
	TunIP          string `json:"tunIP,omitempty"`
	TunDNS         string `json:"tunDNS,omitempty"`
	TunName        string `json:"tunName,omitempty"`
	ActiveSessions int    `json:"activeSessions"`
	LaLuneVersion  string `json:"laLuneVersion"`
	LaLuneRemote   string `json:"laLuneRemote"`
}

var statusMu sync.Mutex

// WriteStatus сохраняет текущее состояние в StatusFile.
// LuCI читает этот файл, чтобы показать статус без запросов к демону.
func WriteStatus(st *State) {
	st.mu.Lock()
	snap := StatusSnapshot{
		Connected:      st.Connected,
		LastCoreError:  st.LastCoreError,
		TunIP:          st.LastTunIP,
		TunDNS:         st.LastTunDNS,
		ActiveSessions: st.ActiveSessions,
		CoreVersion:    LocalVersion(),
	}
	st.mu.Unlock()

	snap.TunName = currentTunName()
	if remote, err := FetchLatestVersion(); err == nil {
		snap.RemoteVersion = remote
		snap.UpdateAvailable = remote != "" && remote != snap.CoreVersion
	}

	laLuneLocal, laLuneRemote, laLuneUpdate := CheckLaLuneUpdate()
	_ = laLuneUpdate
	snap.LaLuneVersion = laLuneLocal
	snap.LaLuneRemote = laLuneRemote

	data, err := json.MarshalIndent(snap, "", "  ")
	if err != nil {
		return
	}

	statusMu.Lock()
	defer statusMu.Unlock()
	_ = atomicWrite(StatusFile, data, 0644)
}

// currentTunName берёт имя из глобального store, если он уже инициализирован.
var globalStore *ConfigStore

func currentTunName() string {
	if globalStore == nil {
		return "csqtt0"
	}
	name := globalStore.GetSettings().TunName
	if name == "" {
		return "csqtt0"
	}
	return name
}
