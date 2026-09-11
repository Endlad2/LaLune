package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"time"
)

// Unix-сокет для IPC между CLI и запущенным демоном.
// Демон слушает /var/run/lalune/daemon.sock, CLI при connect/disconnect
// посылает команду по сокету.
const IPCSocket = RunDir + "/daemon.sock"

// IPCRequest — то, что CLI отправляет демону.
type IPCRequest struct {
	Method string            `json:"method"`
	Args   map[string]string `json:"args,omitempty"`
}

// IPCResponse — ответ демона.
type IPCResponse struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
	Data  string `json:"data,omitempty"`
}

// StartIPCServer поднимает unix-сокет внутри демона.
// handle вызывается для каждой команды, ответ возвращается строкой.
func StartIPCServer(handle func(method string, args map[string]string) (string, error)) error {
	_ = os.Remove(IPCSocket)
	ln, err := net.Listen("unix", IPCSocket)
	if err != nil {
		return err
	}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go handleIPCConn(conn, handle)
		}
	}()
	return nil
}

func handleIPCConn(conn net.Conn, handle func(string, map[string]string) (string, error)) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(30 * time.Second))

	reader := bufio.NewReader(conn)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		return
	}

	var req IPCRequest
	if err := json.Unmarshal(line, &req); err != nil {
		resp, _ := json.Marshal(IPCResponse{OK: false, Error: err.Error()})
		conn.Write(resp)
		conn.Write([]byte("\n"))
		return
	}

	data, err := handle(req.Method, req.Args)
	resp := IPCResponse{OK: err == nil}
	if err != nil {
		resp.Error = err.Error()
	} else {
		resp.Data = data
	}
	enc, _ := json.Marshal(resp)
	conn.Write(enc)
	conn.Write([]byte("\n"))
}

// ipcCall — клиентская часть: посылает команду демону и печатает ответ.
func ipcCall(method string, args map[string]string) {
	conn, err := net.Dial("unix", IPCSocket)
	if err != nil {
		fmt.Fprintf(os.Stderr, `{"error":"%s: daemon not running?"}`+"\n", err.Error())
		os.Exit(1)
	}
	defer conn.Close()

	req := IPCRequest{Method: method, Args: args}
	enc, _ := json.Marshal(req)
	enc = append(enc, '\n')
	if _, err := conn.Write(enc); err != nil {
		fmt.Fprintf(os.Stderr, `{"error":%q}`+"\n", err.Error())
		os.Exit(1)
	}

	reader := bufio.NewReader(conn)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		fmt.Fprintf(os.Stderr, `{"error":%q}`+"\n", err.Error())
		os.Exit(1)
	}

	var resp IPCResponse
	_ = json.Unmarshal(line, &resp)
	if !resp.OK {
		fmt.Fprintf(os.Stderr, `{"error":%q}`+"\n", resp.Error)
		os.Exit(1)
	}
	if resp.Data != "" {
		fmt.Println(resp.Data)
	} else {
		fmt.Println(`{"ok":true}`)
	}
}
