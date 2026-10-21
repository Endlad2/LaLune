// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Мост к Core/csqtt-link (staticlib) для iOS.
// Линкуется в LaLuneTunnel extension.

#ifndef CSQTT_LINK_BRIDGE_H
#define CSQTT_LINK_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// Парсит csqtt:// ссылку, возвращает JSON-строку (malloc).
// Освобождать через csqtt_link_free.
char* csqtt_link_parse(const char* input);

// Возвращает csqtt://connect?... (malloc). Освобождать через csqtt_link_free.
char* csqtt_link_decode(const char* input);

// Освобождает строку, возвращённую выше.
void csqtt_link_free(char* ptr);

// Последняя ошибка (thread-local).
const char* csqtt_link_last_error(void);
void csqtt_link_clear_error(void);

#ifdef __cplusplus
}
#endif

#endif
