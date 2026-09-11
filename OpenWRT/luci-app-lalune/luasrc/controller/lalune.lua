module("luci.controller.lalune", package.seeall)

function index()
    -- Главная страница "Соединение"
    entry({"admin", "services", "lalune"},
          template("lalune/status"),
          _("LaLune"), 90).dependent = true

    -- Конфиги (CBI-форма)
    entry({"admin", "services", "lalune", "configs"},
          cbi("lalune/configs"),
          _("Конфиги"), 91).dependent = true

    -- Настройки (CBI-форма)
    entry({"admin", "services", "lalune", "settings"},
          cbi("lalune/settings"),
          _("Настройки"), 92).dependent = true

    -- Логи
    entry({"admin", "services", "lalune", "logs"},
          template("lalune/logs"),
          _("Логи"), 93).dependent = true

    -- Информация + обновления
    entry({"admin", "services", "lalune", "info"},
          template("lalune/info"),
          _("Информация"), 94).dependent = true

    -- ===== API эндпоинты (AJAX) =====
    entry({"admin", "services", "lalune", "api", "status"},
          call("api_status")).leaf = true
    entry({"admin", "services", "lalune", "api", "version"},
          call("api_version")).leaf = true
    entry({"admin", "services", "lalune", "api", "core-check"},
          call("api_core_check")).leaf = true
    entry({"admin", "services", "lalune", "api", "core-update"},
          call("api_core_update")).leaf = true
    entry({"admin", "services", "lalune", "api", "lalune-check"},
          call("api_lalune_check")).leaf = true
    entry({"admin", "services", "lalune", "api", "connect"},
          call("api_connect")).leaf = true
    entry({"admin", "services", "lalune", "api", "disconnect"},
          call("api_disconnect")).leaf = true
    entry({"admin", "services", "lalune", "api", "configs"},
          call("api_configs")).leaf = true
    entry({"admin", "services", "lalune", "api", "config-add"},
          call("api_config_add")).leaf = true
    entry({"admin", "services", "lalune", "api", "config-delete"},
          call("api_config_delete")).leaf = true
    entry({"admin", "services", "lalune", "api", "device-id"},
          call("api_device_id")).leaf = true
    entry({"admin", "services", "lalune", "api", "device-id-regenerate"},
          call("api_device_id_regenerate")).leaf = true
    entry({"admin", "services", "lalune", "api", "logs"},
          call("api_logs")).leaf = true
end

-- ============ API handlers ============

local function run(cmd)
    return luci.sys.exec(cmd .. " 2>/dev/null")
end

local function json_response(str)
    luci.http.prepare_content("application/json")
    luci.http.write(str or "")
end

function api_status()
    json_response(run("/usr/bin/lalune status"))
end

function api_version()
    json_response(run("/usr/bin/lalune version"))
end

function api_core_check()
    json_response(run("/usr/bin/lalune core-check"))
end

function api_core_update()
    -- Скачивание может занять минуты — увеличим таймаут CGI.
    -- В uhttpd таймаут задаётся конфигом, здесь просто выполним синхронно.
    json_response(run("/usr/bin/lalune core-update"))
end

function api_lalune_check()
    json_response(run("/usr/bin/lalune lalune-check"))
end

function api_connect()
    local id = luci.http.formvalue("config_id") or ""
    -- Валидация: только цифры
    if not id:match("^%d+$") then
        json_response('{"ok":false,"error":"invalid config_id"}')
        return
    end
    json_response(run("/usr/bin/lalune connect " .. id))
end

function api_disconnect()
    json_response(run("/usr/bin/lalune disconnect"))
end

function api_configs()
    json_response(run("/usr/bin/lalune config-list"))
end

function api_config_add()
    local link = luci.http.formvalue("link") or ""
    if link == "" then
        json_response('{"ok":false,"error":"empty link"}')
        return
    end
    -- Простая защита от инъекции: обрамим в одинарные кавычки с escaping
    local escaped = link:gsub("'", "'\\''")
    json_response(run("/usr/bin/lalune config-add '" .. escaped .. "'"))
end

function api_config_delete()
    local id = luci.http.formvalue("id") or ""
    if not id:match("^%d+$") then
        json_response('{"ok":false,"error":"invalid id"}')
        return
    end
    json_response(run("/usr/bin/lalune config-delete " .. id))
end

function api_device_id()
    json_response(run("/usr/bin/lalune device-id"))
end

function api_device_id_regenerate()
    json_response(run("/usr/bin/lalune device-id-regenerate"))
end

function api_logs()
    local data = luci.sys.exec("tail -n 500 /var/log/lalune-core.log 2>/dev/null")
    -- Отдаём как plain text, JS сам разобьёт по строкам
    luci.http.prepare_content("text/plain; charset=utf-8")
    luci.http.write(data or "")
end
