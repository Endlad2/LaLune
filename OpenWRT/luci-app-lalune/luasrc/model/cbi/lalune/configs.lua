local m, s, o

m = Map("lalune", translate("LaLune — Конфиги"),
    translate("Сохранённые конфиги подключения. Добавляются из ссылок csqtt://connect?... или csqtt://user:pass@host:port"))

-- ============ Список существующих конфигов ============
s = m:section(TypedSection, "configs", translate("Сохранённые конфиги"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "configs_list", translate("Все конфиги"))
o.rawhtml = true
o.template = "lalune/configs_list"

-- ============ Добавление нового ============
s = m:section(TypedSection, "add", translate("Добавить конфиг"))
s.anonymous = true
s.addremove = false

o = s:option(Value, "link", translate("Ссылка подключения"))
o.placeholder = "csqtt://connect?v=2&host=...&peer=...&password=...&hashes=..."
o.rmempty = true

-- Кнопка "Добавить" обрабатывается на клиенте через JS в шаблоне.
-- При отправке формы значение link пойдёт в on_before_commit.

function m.on_before_commit(self)
    local link = self.add and self.add.link or nil
    if link and link ~= "" then
        local escaped = link:gsub("'", "'\\''")
        luci.sys.exec("/usr/bin/lalune config-add '" .. escaped .. "' 2>/dev/null")
    end
end

function m.commit(self)
    m.on_before_commit(self)
end

return m
