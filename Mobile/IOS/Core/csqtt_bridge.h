#ifndef CSQTT_BRIDGE_H
#define CSQTT_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Логирование
typedef void (*csqtt_log_callback)(const char* message);

void csqtt_set_log_callback(csqtt_log_callback callback);
const char* csqtt_get_logs(void);
void csqtt_free_logs(char* ptr);
void csqtt_clear_logs(void);

// Запуск ядра
// Возвращает 0 при успехе, -1 при ошибке runtime, -3 при ошибке клиента
int csqtt_run(
    const char* peer,
    const char* vk,
    const char* password,
    const char* listen,
    int workers,
    const char* device_id,
    const char* vk_hash_mode,
    const char* vk_auth_mode,
    const char* captcha_mode,
    const char* fingerprint,
    const char* client_ids,
    const char* obfs,
    const char* turn_transport,
    uint64_t generation,
    const char* salt,
    const char* turn,
    const char* port,
    bool allow_hash_redistribution,
    bool validate_vk_hashes,
    const char* tun_uds
);

// Остановка ядра
int csqtt_stop(void);

// Статус (1 = работает, 0 = нет)
int csqtt_status(void);

#ifdef __cplusplus
}
#endif

#endif // CSQTT_BRIDGE_H
