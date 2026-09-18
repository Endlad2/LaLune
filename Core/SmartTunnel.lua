-- SPDX-FileCopyrightText: 2026 luminescq
-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
--
-- SmartTunnel.lua — скрипт для встроенного Lua 5.1-рантайма SmartTunnel.
--
-- Эмбедится в Go-бинарник через //go:embed SmartTunnel.lua
-- в Desktop/Libs/smarttunnel.go. Копируется в Desktop/Libs/ скриптом
-- prepare_st.py ПЕРЕД сборкой Go.
--
-- Этот файл — заглушка. Если у вас есть настоящий скрипт — замените.
--
-- Доступный API (см. smarttunnel.go / registerAPI):
--   smarttunnel.log(msg)              — писать в лог
--   smarttunnel.logs()                — вернуть массив накопленных логов
--   smarttunnel.connect()             — (не реализовано) → false
--   smarttunnel.disconnect()          — (не реализовано) → false
--   smarttunnel.is_connected()        — bool
--   smarttunnel.set_args(list)        — сохранить список строк
--   smarttunnel.get_args()            — вернуть список строк
--   smarttunnel.get_vk_creds()        — { token, hashes, userId, expiresIn }
--   smarttunnel.get_setting(key)      — значение настройки или nil
--   smarttunnel.set_setting(key, val) — записать настройку (в память)

-- Вызывается один раз при старте рантайма.
function on_load()
    smarttunnel.log("[SMART-TUNNEL] on_load")
end

-- Вызывается раз в секунду (tickInterval = 1s в smarttunnel.go).
function on_tick()
    -- Заглушка: ничего не делаем каждую секунду.
    --
    -- Здесь может быть логика вида:
    --   if not smarttunnel.is_connected() then
    --       local creds = smarttunnel.get_vk_creds()
    --       if creds.token ~= "" then
    --           smarttunnel.connect()
    --       end
    --   end
end
