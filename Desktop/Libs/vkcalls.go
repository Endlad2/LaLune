package libs

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// ============================================================
//  VK Auto API — создание/завершение звонков через VK API
// ============================================================
// Прямой перенос VkAutoCallsManager из FOCSQ (Dart) на Go.
//
// Endpoint: https://api.vk.ru/method/calls.start
// Авторизация: header "Authorization: Bearer <token>"
// Content-Type: application/x-www-form-urlencoded
// Version: 5.199 в теле

const (
	VkApiBase    = "https://api.vk.ru/method/"
	VkApiVersion = "5.199"

	vkMaxHashes          = 6
	vkGroupsPerHash      = 3
	vkWorkersPerGroup    = 9
	vkMaxAttemptsPerCall = 3
	vkSmallDelayMs       = 80
	vkLargeDelayMs       = 202
)

var vkTokenInvalidCodes = map[int]bool{4: true, 5: true, 27: true, 28: true}

// VkApiClient — минимальный клиент VK API.
type VkApiClient struct {
	http *http.Client
}

func NewVkApiClient() *VkApiClient {
	return &VkApiClient{
		http: &http.Client{Timeout: 8 * time.Second},
	}
}

func (c *VkApiClient) call(method, token string, params map[string]string) (map[string]interface{}, error) {
	uri := VkApiBase + method

	form := url.Values{}
	for k, v := range params {
		form.Set(k, v)
	}
	form.Set("v", VkApiVersion)

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

// VkCallStartResult — результат попытки создать звонок.
type VkCallStartResult struct {
	CallID       string
	Hash         string
	ErrorCode    int
	ErrorMessage string
	Failed       bool
}

func (r VkCallStartResult) IsSuccess() bool { return r.CallID != "" && r.Hash != "" }

// StartCall — создаёт один звонок, возвращает call_id + hash.
//
// Логика хеша (из FOCSQ auto_calls.dart):
//   1. Берём ok_join_link, обрезаем пробелы — это хеш.
//   2. Если ok_join_link пустой — берём последний сегмент join_link по '/'.
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

// ForceFinishCall — завершает звонок.
func (c *VkApiClient) ForceFinishCall(token, callID string) bool {
	j, err := c.call("calls.forceFinish", token, map[string]string{"call_id": callID})
	if err != nil {
		return false
	}
	_, hasErr := j["error"]
	return !hasErr
}

// ============================================================
//  VkAutoCallsManager — высокоуровневый менеджер
// ============================================================

type VkAutoCallsManager struct {
	client          *VkApiClient
	tokenInvalidSeen bool
}

func NewVkAutoCallsManager() *VkAutoCallsManager {
	return &VkAutoCallsManager{client: NewVkApiClient()}
}

func (m *VkAutoCallsManager) TokenInvalidSeen() bool { return m.tokenInvalidSeen }

// CallCountForWorkers — сколько звонков нужно для N воркеров.
// 1 звонок = 3 группы × 9 воркеров = 27 воркеров, максимум 6 звонков.
func CallCountForWorkers(workers int) int {
	for n := 1; n <= vkMaxHashes; n++ {
		if workers <= n*vkGroupsPerHash*vkWorkersPerGroup {
			return n
		}
	}
	return vkMaxHashes
}

// VkAutoCall — один созданный звонок.
type VkAutoCall struct {
	CallID string
	Hash   string
}

// VkCallsBatch — результат пакетного создания.
type VkCallsBatch struct {
	Calls           []VkAutoCall
	RequestedCalls  int
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

// NeedsWorkerRedistribution — true, если создали меньше звонков, чем просили.
func (b *VkCallsBatch) NeedsWorkerRedistribution() bool {
	return len(b.Calls) < b.RequestedCalls
}

// CreateForWorkers — создаёт нужное количество звонков.
// onProgress(created, total) — колбэк для UI.
func (m *VkAutoCallsManager) CreateForWorkers(
	token string,
	workers int,
	onProgress func(created, total int),
	log func(string),
) *VkCallsBatch {
	if strings.TrimSpace(token) == "" {
		return nil
	}

	count := CallCountForWorkers(workers)
	var delay time.Duration
	if count <= 4 {
		delay = vkSmallDelayMs * time.Millisecond
	} else {
		delay = vkLargeDelayMs * time.Millisecond
	}

	calls := make([]VkAutoCall, 0, count)
	m.tokenInvalidSeen = false

	for slot := 0; slot < count; slot++ {
		if slot > 0 {
			time.Sleep(delay)
		}

		tokenInvalid := false
		var result VkCallStartResult

		for attempt := 0; attempt < vkMaxAttemptsPerCall; attempt++ {
			result = m.client.StartCall(token)
			if result.IsSuccess() {
				break
			}
			if vkTokenInvalidCodes[result.ErrorCode] {
				break
			}
		}

		if result.IsSuccess() {
			calls = append(calls, VkAutoCall{CallID: result.CallID, Hash: result.Hash})
		} else if result.Failed && result.ErrorMessage != "" {
			if log != nil {
				log(fmt.Sprintf("[АВТО API] Звонок не создан · код=%d %s",
					result.ErrorCode, result.ErrorMessage))
			}
			tokenInvalid = vkTokenInvalidCodes[result.ErrorCode]
			if tokenInvalid {
				m.tokenInvalidSeen = true
			}
		}

		if onProgress != nil {
			onProgress(len(calls), count)
		}

		if tokenInvalid {
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

// FinishAll — завершает все звонки параллельно.
func (m *VkAutoCallsManager) FinishAll(token string, callIds []string, log func(string)) int {
	if strings.TrimSpace(token) == "" || len(callIds) == 0 {
		return 0
	}

	type res struct{ ok bool }
	ch := make(chan res, len(callIds))

	for _, id := range callIds {
		go func(callID string) {
			ok := m.client.ForceFinishCall(token, callID)
			ch <- res{ok: ok}
		}(id)
	}

	finished := 0
	timeout := time.After(8 * time.Second)
	for i := 0; i < len(callIds); i++ {
		select {
		case r := <-ch:
			if r.ok {
				finished++
			}
		case <-timeout:
			i = len(callIds)
		}
	}

	if log != nil {
		log(fmt.Sprintf("[АВТО API] Звонки завершены %d/%d", finished, len(callIds)))
	}
	return finished
}

func (m *VkAutoCallsManager) Close() {}

// ============================================================
//  Публичные обёртки для AppCore (используются UI-биндингами)
// ============================================================

// RunVkAutoApiCalls — высокоуровневая функция: берёт токен из settings,
// создаёт звонки, сохраняет хеши в settings. Возвращает массив хешей.
//
// Вызывается из UI через Wails-биндинг перед запуском ядра.
func (a *AppCore) RunVkAutoApiCalls(onLog func(string)) ([]string, []string, error) {
	token := a.GetVKToken()
	if token == "" {
		return nil, nil, fmt.Errorf("токен ВК не получен")
	}

	workers := a.GetSettings().WorkersPerHash
	if workers < 9 {
		workers = 9
	}

	mgr := NewVkAutoCallsManager()
	defer mgr.Close()

	batch := mgr.CreateForWorkers(token, workers, nil, onLog)
	if batch == nil {
		if mgr.TokenInvalidSeen() {
			a.DeleteVKToken()
			return nil, nil, fmt.Errorf("токен ВК недействителен — выполните вход заново")
		}
		return nil, nil, fmt.Errorf("не удалось создать звонки VK")
	}

	return batch.Hashes(), batch.CallIds(), nil
}

// GetVKToken — читает токен из settings (VkJsToken).
func (a *AppCore) GetVKToken() string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.settings.VkJsToken
}

// FinishVkCalls — завершает указанные звонки. Используется при disconnect.
func (a *AppCore) FinishVkCalls(callIds []string) {
	token := a.GetVKToken()
	if token == "" || len(callIds) == 0 {
		return
	}
	mgr := NewVkAutoCallsManager()
	mgr.FinishAll(token, callIds, func(s string) { a.AddLog(s) })
	mgr.Close()
}

// ============================================================
//  Утилиты
// ============================================================

func numFromAny(v interface{}) float64 {
	switch x := v.(type) {
	case float64:
		return x
	case int:
		return float64(x)
	case int64:
		return float64(x)
	}
	return 0
}

func strFromAny(v interface{}) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprintf("%v", v)
}

func splitNonEmpty(s string, sep rune) []string {
	var out []string
	for _, p := range strings.Split(s, string(sep)) {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
