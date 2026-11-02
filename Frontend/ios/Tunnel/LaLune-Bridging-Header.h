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
    const char* peer, const char* vk, const char* password, const char* listen,
    int workers, const char* vk_hash_mode, const char* vk_auth_mode,
    const char* captcha_mode, const char* fingerprint, const char* client_ids,
    const char* obfs, const char* turn_transport, const char* srtp_mode,
    uint64_t generation, const char* salt, const char* turn,
    const char* custom_turn_ips, const char* port, bool validate_vk_hashes,
    const char* tun_uds, bool domain_routing, bool exclude_ru_zones,
    bool template_domains, bool domain_whitelist, const char* direct_domains,
    bool ip_routing, bool ip_whitelist, const char* direct_ips, bool exact_workers
);
int csqtt_stop(void);
int csqtt_status(void);

void csqttr_set_log_callback(csqtt_log_callback callback);
const char* csqttr_get_logs(void);
void csqttr_free_logs(char* ptr);
void csqttr_clear_logs(void);

int csqttr_run_extended(
    const char* peer, const char* vk, const char* password, const char* listen,
    int workers, const char* vk_hash_mode, const char* vk_auth_mode,
    const char* captcha_mode, const char* fingerprint, const char* client_ids,
    const char* obfs, const char* turn_transport, const char* srtp_mode,
    uint64_t generation, const char* salt, const char* turn,
    const char* custom_turn_ips, const char* port, bool validate_vk_hashes,
    const char* tun_uds, bool domain_routing, bool exclude_ru_zones,
    bool template_domains, bool domain_whitelist, const char* direct_domains,
    bool ip_routing, bool ip_whitelist, const char* direct_ips, bool exact_workers
);
int csqttr_stop(void);
int csqttr_status(void);

#endif
