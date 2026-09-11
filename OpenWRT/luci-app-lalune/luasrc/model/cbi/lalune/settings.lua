local m, s, o

m = Map("lalune", translate("LaLune — Настройки"),
    translate("Основные параметры клиента. Значения сохраняются в /etc/lalune/settings.json через бэкенд lalune."))

-- ============ Основные ============
s = m:section(TypedSection, "lalune", translate("Основные"))
s.anonymous = true

o = s:option(Value, "peer", translate("Peer (host:port)"))
o.placeholder = "31.77.148.203:46000"
o.rmempty = true

o = s:option(Value, "password", translate("Пароль"))
o.password = true
o.rmempty = true

o = s:option(Value, "vkHashes", translate("VK Hashes (через запятую)"))
o.placeholder = "hash1,hash2,hash3"
o.rmempty = true

o = s:option(Value, "workersPerHash", translate("Воркеров на хеш"))
o.datatype = "uinteger"
o.default = "9"
o.rmempty = true

-- ============ Продвинутые ============
s = m:section(TypedSection, "advanced", translate("Продвинутые"))
s.anonymous = true

o = s:option(ListValue, "obfs", translate("Obfs"))
o:value("video", "video")
o:value("audio", "audio")
o:value("text", "text")
o.default = "video"
o.rmempty = true

o = s:option(ListValue, "fingerprint", translate("Fingerprint"))
o:value("firefox", "firefox")
o:value("chrome", "chrome")
o:value("edge", "edge")
o.default = "firefox"
o.rmempty = true

o = s:option(Value, "clientIds", translate("Client IDs"))
o.placeholder = "8202606,6287487"
o.rmempty = true

o = s:option(Value, "turnHost", translate("Turn Host (опционально)"))
o.rmempty = true

o = s:option(Value, "turnPort", translate("Turn Port (опционально)"))
o.rmempty = true

o = s:option(Flag, "autoConnect", translate("Автоподключение при старте"))
o.default = "0"
o.rmempty = true

o = s:option(Value, "tunName", translate("Имя TUN-интерфейса"))
o.default = "csqtt0"
o.rmempty = true

-- ============ Device ID ============
s = m:section(TypedSection, "device", translate("Device ID"))
s.anonymous = true

o = s:option(DummyValue, "deviceId", translate("Device ID"))
o.rawhtml = true
o.template = "lalune/device_id_field"

-- ============ Обработчики ============

-- Перед сохранением подтягиваем текущие значения из /etc/lalune/settings.json
-- через CLI, чтобы поля были актуальны. Это делается в on_parse.
function m.on_parse(self)
    local json = luci.sys.exec("/usr/bin/lalune settings-get 2>/dev/null")
    local ok, data = pcall(function() return luci.jsonc.parse(json) end)
    if ok and data then
        self.lalune = {
            peer = data.peer or "",
            password = data.password or "",
            vkHashes = data.vkHashes or "",
            workersPerHash = tostring(data.workersPerHash or 9),
            obfs = data.obfs or "video",
            fingerprint = data.fingerprint or "firefox",
            clientIds = data.clientIds or "",
            turnHost = data.turnHost or "",
            turnPort = data.turnPort or "",
            autoConnect = data.autoConnect and "1" or "0",
            tunName = data.tunName or "csqtt0",
            deviceId = data.deviceId or "",
        }
    end
end

function m.parse(self)
    m.on_parse(self)
end

-- После сохранения — собираем JSON и отдаём в CLI.
function m.on_before_commit(self)
    local json = {
        peer = self.lalune.peer or "",
        password = self.lalune.password or "",
        vkHashes = self.lalune.vkHashes or "",
        workersPerHash = tonumber(self.lalune.workersPerHash) or 9,
        obfs = self.lalune.obfs or "video",
        fingerprint = self.lalune.fingerprint or "firefox",
        clientIds = self.lalune.clientIds or "",
        turnHost = self.lalune.turnHost or "",
        turnPort = self.lalune.turnPort or "",
        autoConnect = self.lalune.autoConnect == "1",
        tunName = self.lalune.tunName or "csqtt0",
        deviceId = self.lalune.deviceId or "",
    }
    local payload = luci.jsonc.stringify(json)
    local escaped = payload:gsub("'", "'\\''")
    luci.sys.exec("/usr/bin/lalune settings-set '" .. escaped .. "' 2>/dev/null")
end

function m.commit(self)
    m.on_before_commit(self)
end

return m
