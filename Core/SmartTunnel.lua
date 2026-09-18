-- SPDX-FileCopyrightText: 2026 luminescq
-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
--
-- SmartTunnel.lua — MVP-скрипт для управления туннелем CSQTT.
--
-- Рантайм: Lua 5.1 (совместимо с gopher-lua и LuaJ).
--
-- Доступное API (глобальная таблица `smarttunnel`):
--   smarttunnel.log(message)                  — записать строку в общий лог
--   smarttunnel.logs()                        — вернуть массив последних строк лога
--   smarttunnel.connect()                     — запустить туннель
--   smarttunnel.disconnect()                  — остановить туннель
--   smarttunnel.is_connected()                — true/false
--   smarttunnel.set_args(table)               — заменить аргументы запуска ядра
--   smarttunnel.get_args()                    — вернуть текущие аргументы
--   smarttunnel.get_vk_creds()                — { token=..., hashes=..., userId=..., expiresIn=... }
--   smarttunnel.get_setting(key)              — прочитать настройку из settings.json
--   smarttunnel.set_setting(key, value)       — записать настройку (в память, не сохраняется)
--
-- Точки входа (опциональные):
--   function on_load()      — вызывается один раз при старте
--   function on_tick()      — вызывается раз в секунду
--   function on_connect()   — вызывается при подключении
--   function on_disconnect()— вызывается при отключении
--   function on_log(line)   — вызывается на каждую новую строку лога

local tick_counter = 0

function on_load()
    smarttunnel.log("[SMART-TUNNEL] Загружен")
end

function on_tick()
    tick_counter = tick_counter + 1
    if tick_counter >= 10 then
        tick_counter = 0
        smarttunnel.log("[SMART-TUNNEL] Еще не реализовано")
    end
end
