// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// DeployManager runner: запускает Rust-бинарь Core/DeployManager, который
// ставит выбранный протокол (core) на удалённый сервер по SSH.
// Бинарь кладётся рядом с исполняемым файлом LaLune при сборке
// (см. build_deploy_manager.py / build_desktop.py).

package libs

import (
	"bufio"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
)

// DeployRequest — данные, приходящие из UI (вкладка "Деплой").
type DeployRequest struct {
	Protocol    string `json:"protocol"`
	Host        string `json:"host"`
	SSHPort     int    `json:"sshPort"`
	User        string `json:"user"`
	UsePassword bool   `json:"usePassword"`
	Password    string `json:"password"`
	KeyPath     string `json:"keyPath"`
	ManualPorts bool   `json:"manualPorts"`
	CorePort    int    `json:"corePort"`
	WarpPort    int    `json:"warpPort"`
	ListenPort  int    `json:"listenPort"`
}

var (
	deployMu   sync.Mutex
	deployLog  strings.Builder
	deployBusy bool
)

// deployManagerName — имя бинаря DeployManager для текущей ОС.
func deployManagerName() string {
	if runtime.GOOS == "windows" {
		return "deploy-manager.exe"
	}
	return "deploy-manager"
}

// resolveDeployManagerPath ищет бинарь рядом с exe, затем в cwd.
func resolveDeployManagerPath() string {
	name := deployManagerName()
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		candidates := []string{
			filepath.Join(dir, name),
			filepath.Join(dir, "bin", name),
		}
		for _, c := range candidates {
			if st, err := os.Stat(c); err == nil && !st.IsDir() {
				return c
			}
		}
	}
	if wd, err := os.Getwd(); err == nil {
		if st, err := os.Stat(filepath.Join(wd, name)); err == nil && !st.IsDir() {
			return filepath.Join(wd, name)
		}
	}
	return ""
}

func deployAppend(line string) {
	deployMu.Lock()
	deployLog.WriteString(line)
	deployLog.WriteString("\n")
	deployMu.Unlock()
}

// DeployProtocol запускает деплой протокола. Возвращает false если
// DeployManager уже запущен или бинарь не найден.
func DeployProtocol(reqJSON string) bool {
	deployMu.Lock()
	if deployBusy {
		deployMu.Unlock()
		return false
	}
	deployLog.Reset()
	deployMu.Unlock()

	var req DeployRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		deployAppend("[deploy] ошибка разбора параметров: " + err.Error())
		return false
	}
	if strings.TrimSpace(req.Host) == "" {
		deployAppend("[deploy] не указан хост")
		return false
	}

	binPath := resolveDeployManagerPath()
	if binPath == "" {
		deployAppend("[deploy] не найден deploy-manager рядом с LaLune")
		return false
	}

	args := []string{
		"deploy",
		"--protocol", strings.ToLower(strings.TrimSpace(req.Protocol)),
		"--host", req.Host,
		"--user", req.User,
	}
	if req.SSHPort > 0 {
		args = append(args, "--port", itoa(req.SSHPort))
	}
	if req.UsePassword {
		if req.Password != "" {
			args = append(args, "--password", req.Password)
		}
	} else if req.KeyPath != "" {
		args = append(args, "--key", req.KeyPath)
	}
	if req.ManualPorts {
		args = append(args, "--manual-ports")
		if req.CorePort > 0 {
			args = append(args, "--core-port", itoa(req.CorePort))
		}
		if req.WarpPort > 0 {
			args = append(args, "--warp-port", itoa(req.WarpPort))
		}
		if req.ListenPort > 0 {
			args = append(args, "--listen-port", itoa(req.ListenPort))
		}
	}

	cmd := exec.Command(binPath, args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		deployAppend("[deploy] ошибка запуска: " + err.Error())
		return false
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		deployAppend("[deploy] ошибка запуска: " + err.Error())
		return false
	}

	if err := cmd.Start(); err != nil {
		deployAppend("[deploy] не удалось запустить DeployManager: " + err.Error())
		return false
	}

	deployMu.Lock()
	deployBusy = true
	deployMu.Unlock()
	deployAppend("[deploy] DeployManager запущен для " + req.Protocol + " → " + req.Host)

	go func() {
		scanOut := bufio.NewScanner(stdout)
		for scanOut.Scan() {
			deployAppend(scanOut.Text())
		}
		scanErr := bufio.NewScanner(stderr)
		for scanErr.Scan() {
			deployAppend(scanErr.Text())
		}
		err := cmd.Wait()
		if err != nil {
			deployAppend("[deploy] завершено с ошибкой: " + err.Error())
		} else {
			deployAppend("[deploy] завершено успешно")
		}
		deployMu.Lock()
		deployBusy = false
		deployMu.Unlock()
	}()

	return true
}

// DeployLog возвращает накопленный журнал деплоя.
func DeployLog() string {
	deployMu.Lock()
	defer deployMu.Unlock()
	return deployLog.String()
}

// DeployBusy сообщает, идёт ли деплой сейчас.
func DeployBusy() bool {
	deployMu.Lock()
	defer deployMu.Unlock()
	return deployBusy
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
