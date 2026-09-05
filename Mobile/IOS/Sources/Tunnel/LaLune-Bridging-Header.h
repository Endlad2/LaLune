#ifndef LALUNE_TUNNEL_BRIDGING_H
#define LALUNE_TUNNEL_BRIDGING_H

#include <stdint.h>
#include <stdbool.h>

typedef void (*csqtt_log_callback)(const char* message);

void csqtt_set_log_callback(csqtt_log_callback callback);
const char* csqtt_get_logs(void);
void csqtt_free_logs(char* ptr);
void csqtt_clear_logs(void);

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

int csqtt_stop(void);
int csqtt_status(void);

#endif
