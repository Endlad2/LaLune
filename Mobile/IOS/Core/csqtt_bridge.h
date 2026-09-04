#ifndef CSQTT_BRIDGE_H
#define CSQTT_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Запуск ядра CSQTT
// Возвращает 0 при успехе, -1 при ошибке
int csqtt_core_start(
    const char* peer,
    const char* password,
    const char* hashes,
    int workers,
    uint16_t listen_port
);

// Остановка ядра
void csqtt_core_stop(void);

// Получение TUN IP (вызывать после start)
// Возвращает строку вида "10.66.67.12" или NULL
const char* csqtt_core_get_tun_ip(void);

// Получение DNS серверов (вызывать после start)
// Возвращает строку вида "8.8.8.8,8.8.4.4" или NULL
const char* csqtt_core_get_dns(void);

// Проверка статуса
// Возвращает 1 если ядро работает, 0 если нет
int csqtt_core_is_running(void);

#ifdef __cplusplus
}
#endif

#endif // CSQTT_BRIDGE_H
