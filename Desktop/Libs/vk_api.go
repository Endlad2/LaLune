// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// vk_api.go — клиент VK API для создания/завершения звонков (режим Авто API).
// Порт с Dart-версии VkAutoCallsManager.
//
// Endpoint: https://api.vk.ru/method/
// Авторизация: header "Authorization: Bearer <token>"
// Content-Type: application/x-www-form-urlencoded
// Version: 5.199 (в теле)
//
// Токен берётся ТОЛЬКО из token.json (см. ReadTokenFromFile).
// Логи помечаются префиксом "[АВТО API]" — как в оригинальном Dart-коде.

package libs

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ============================================================
//  Константы
// ============================================================

const (
	vkApiBase    = "https://api.vk.ru/method/"
	vkApiVersion = "5.199"

	vkMaxHashes          = 6
	vkMaxAttemptsPerCall = 3
	vkSmallDelayMs       = 80
	vkLargeDelayMs       = 202
	vkFinishTimeoutSec   = 8
)

// vkTokenInvalidCodes — коды ошибок VK, означающие невалидный токен.
var vkTokenInvalidCodes = map[int]bool{4: true, 5: true, 27: true, 28: true}

// ============================================================
//  VK API client
// ============================================================

type VkApiClient struct {
	http    *http.Client
	timeout time.Duration
}

func NewVkApiClient() *VkApiClient {
	return &VkApiClient{
		http:    &http.Client{Timeout: 8 * time.Second},
		timeout: 8 * time.Second,
	}
}

func (c *VkApiClient) call(method, token string, params map[string]string) (map[string]interface{}, error) {
	uri := vkApiBase + method

	form := url.Values{}
	for k, v := range params {
		form.Set(k, v)
	}
	form.Set("v", vkApiVersion)

	req, err := http.NewRequest("POST", uri, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if len(body) == 0 {
		return nil, fmt.Errorf("empty response")
	}

	var m map[string]interface{}
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, err
	}
	return m, nil
}

func (c *VkApiClient) Close() {}

// ============================================================
//  calls.start / calls.forceFinish
// ============================================================

type VkCallStartResult struct {
	CallID       string
	Hash         string
	ErrorCode    int
	ErrorMessage string
	Failed       bool
}

func (r VkCallStartResult) IsSuccess() bool {
	return r.CallID != "" && r.Hash != ""
}

func (r VkCallStartResult) TokenInvalid() bool {
	return vkTokenInvalidCodes[r.ErrorCode]
}

// StartCall создаёт один звонок (calls.start).
func (c *VkApiClient) StartCall(token string) VkCallStartResult {
	j, err := c.call("calls.start", token, map[string]string{})
	if err != nil {
		return VkCallStartResult{Failed: true, ErrorMessage: err.Error()}
	}

	if e, ok := j["error"].(map[string]interface{}); ok {
		code := int(numFromAny(e["error_code"]))
		msg := strFromAny(e["error_msg"])
		return VkCallStartResult{ErrorCode: code, ErrorMessage: msg, Failed: true}
	}

	resp, ok := j["response"].(map[string]interface{})
	if !ok {
		return VkCallStartResult{Failed: true, ErrorMessage: "нет response в calls.start"}
	}

	callID := strFromAny(resp["call_id"])
	joinLink := strFromAny(resp["join_link"])
	okJoinLink := strFromAny(resp["ok_join_link"])

	hash := strings.TrimSpace(okJoinLink)
	if hash == "" && joinLink != "" {
		segments := splitNonEmpty(joinLink, '/')
		if len(segments) > 0 {
			hash = segments[len(segments)-1]
		}
	}

	if callID == "" || hash == "" {
		return VkCallStartResult{Failed: true, ErrorMessage: "пустой call_id/hash"}
	}

	return VkCallStartResult{CallID: callID, Hash: hash}
}

// ForceFinishCall завершает звонок (calls.forceFinish).
func (c *VkApiClient) ForceFinishCall(token, callID string) bool {
	j, err := c.call("calls.forceFinish", token, map[string]string{"call_id": callID})
	if err != nil {
		return false
	}
	_, hasErr := j["error"]
	return !hasErr
}

// ============================================================
//  VkAutoCallsManager
// ============================================================

type VkAutoCallsManager struct {
	client           *VkApiClient
	tokenInvalidSeen bool
	mu               sync.Mutex
}

func NewVkAutoCallsManager() *VkAutoCallsManager {
	return &VkAutoCallsManager{client: NewVkApiClient()}
}

func (m *VkAutoCallsManager) TokenInvalidSeen() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.tokenInvalidSeen
}

// CallCountForWorkers — сколько звонков нужно создать.
//   callsCount = ceil(workers / autoApiWorkers), ограничено 1..6.
//
// Пример: workers=27, autoApiWorkers=9 → 3 звонка.
//         workers=25, autoApiWorkers=9 → ceil(25/9)=3 звонка.
//         workers=10, autoApiWorkers=9 → ceil(10/9)=2 звонка.
func CallCountForWorkers(workers, autoApiWorkers int) int {
	if autoApiWorkers <= 0 {
		autoApiWorkers = DefaultAutoApiWorkers
	}
	if workers <= 0 {
		workers = DefaultWorkers
	}

	count := int(math.Ceil(float64(workers) / float64(autoApiWorkers)))

	if count < 1 {
		count = 1
	}
	if count > vkMaxHashes {
		count = vkMaxHashes
	}
	return count
}

type VkAutoCall struct {
	CallID string
	Hash   string
}

type VkCallsBatch struct {
	Calls          []VkAutoCall
	RequestedCalls int
}

func (b *VkCallsBatch) Hashes() []string {
	out := make([]string, len(b.Calls))
	for i, c := range b.Calls {
		out[i] = c.Hash
	}
	return out
}

func (b *VkCallsBatch) CallIds() []string {
	out := make([]string, len(b.Calls))
	for i, c := range b.Calls {
		out[i] = c.CallID
	}
	return out
}

func (b *VkCallsBatch) NeedsWorkerRedistribution() bool {
	return len(b.Calls) < b.RequestedCalls
}

func (m *VkAutoCallsManager) startCallWithAttempts(token string) VkCallStartResult {
	var last VkCallStartResult
	for attempt := 0; attempt < vkMaxAttemptsPerCall; attempt++ {
		last = m.client.StartCall(token)
		if last.IsSuccess() {
			return last
		}
		if last.TokenInvalid() {
			return last
		}
	}
	return last
}

// CreateForWorkers создаёт нужное количество звонков.
//   workers        — общее число воркеров (для расчёта callsCount)
//   autoApiWorkers — сколько воркеров в одном звонке
func (m *VkAutoCallsManager) CreateForWorkers(
	token string,
	workers int,
	autoApiWorkers int,
	onProgress func(created, total int),
	log func(string),
) *VkCallsBatch {
	if strings.TrimSpace(token) == "" {
		return nil
	}

	count := CallCountForWorkers(workers, autoApiWorkers)
	var delay time.Duration
	if count <= 4 {
		delay = vkSmallDelayMs * time.Millisecond
	} else {
		delay = vkLargeDelayMs * time.Millisecond
	}

	calls := make([]VkAutoCall, 0, count)

	m.mu.Lock()
	m.tokenInvalidSeen = false
	m.mu.Unlock()

	for slot := 0; slot < count; slot++ {
		if slot > 0 {
			time.Sleep(delay)
		}

		result := m.startCallWithAttempts(token)

		if result.IsSuccess() {
			calls = append(calls, VkAutoCall{CallID: result.CallID, Hash: result.Hash})
		} else if result.Failed && result.ErrorMessage != "" {
			if result.ErrorCode != 0 {
				if log != nil {
					log(fmt.Sprintf("[АВТО API] Звонок не создан · код=%d %s",
						result.ErrorCode, result.ErrorMessage))
				}
			} else {
				if log != nil {
					log(fmt.Sprintf("[АВТО API] Звонок не создан · %s",
						result.ErrorMessage))
				}
			}
		}

		if onProgress != nil {
			onProgress(len(calls), count)
		}

		if result.TokenInvalid() {
			m.mu.Lock()
			m.tokenInvalidSeen = true
			m.mu.Unlock()
			if log != nil {
				log("[АВТО API] Токен недействителен · войдите снова")
			}
			return nil
		}
	}

	if len(calls) == 0 {
		return nil
	}

	if len(calls) < count && log != nil {
		log(fmt.Sprintf("[АВТО API] Звонки %d/%d · потоки распределены",
			len(calls), count))
	}

	return &VkCallsBatch{
		Calls:          calls,
		RequestedCalls: count,
	}
}

func (m *VkAutoCallsManager) FinishAll(token string, callIds []string, log func(string)) int {
	if strings.TrimSpace(token) == "" || len(callIds) == 0 {
		return 0
	}

	var wg sync.WaitGroup
	var mu sync.Mutex
	finished := 0

	done := make(chan struct{})
	for _, id := range callIds {
		wg.Add(1)
		go func(callID string) {
			defer wg.Done()
			ok := m.client.ForceFinishCall(token, callID)
			if ok {
				mu.Lock()
				finished++
				mu.Unlock()
			}
		}(id)
	}

	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(vkFinishTimeoutSec * time.Second):
	}

	if log != nil {
		log(fmt.Sprintf("[АВТО API] Звонки завершены %d/%d", finished, len(callIds)))
	}
	return finished
}

func (m *VkAutoCallsManager) Close() {
	m.client.Close()
}

// ============================================================
//  Чтение токена из token.json — ЕДИНСТВЕННЫЙ источник токена
// ============================================================

func (a *AppCore) ReadTokenFromFile() string {
	tokenFile := filepath.Join(a.appDir, "token.json")

	data, err := os.ReadFile(tokenFile)
	if err != nil {
		return ""
	}

	var j struct {
		Token string `json:"Token"`
	}
	if err := json.Unmarshal(data, &j); err == nil && strings.TrimSpace(j.Token) != "" {
		return strings.TrimSpace(j.Token)
	}

	var j2 struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(data, &j2); err == nil && strings.TrimSpace(j2.Token) != "" {
		return strings.TrimSpace(j2.Token)
	}

	return ""
}
