var api = null;
var selectedConfigId = null;
var isConnected = false;
var configs = [];
var importMethod = 'manual';
var settings = { peer: '', vkHashes: '', turnHost: '', turnPort: '', workersPerHash: 9, obfs: 'video', fingerprint: 'firefox', clientIds: '8202606,6287487', vkAuthMode: 'vkcalls', captchaMode: 'auto', deviceId: '', autoConnect: false };

function generateStars() {
    var container = document.getElementById('stars');
    for (var i = 0; i < 80; i++) {
        var star = document.createElement('div');
        star.className = 'star';
        var size = 0.5 + Math.random() * 1.8;
        star.style.cssText = 'width:' + size + 'px;height:' + size + 'px;left:' + (Math.random()*100) + '%;top:' + (Math.random()*100) + '%;opacity:' + (0.2+Math.random()*0.7) + ';animation:twinkle ' + (1.5+Math.random()*2) + 's ease-in-out infinite alternate';
        container.appendChild(star);
    }
}

function generateMoonStars() {
    var container = document.getElementById('moonStars');
    if (!container) return;
    container.innerHTML = '';
    for (var i = 0; i < 16; i++) {
        var star = document.createElement('div');
        star.className = 'moon-star';
        var angle = Math.random() * 2 * Math.PI;
        var dist = 40 + Math.random() * 60;
        star.style.cssText = 'left:' + (50+Math.cos(angle)*dist) + '%;top:' + (50+Math.sin(angle)*dist) + '%;width:' + (2+Math.random()*4) + 'px;height:' + (2+Math.random()*4) + 'px;animation-delay:' + (Math.random()*0.6) + 's;animation-duration:' + (0.5+Math.random()*0.5) + 's';
        container.appendChild(star);
    }
}

function switchTab(tab) {
    document.querySelectorAll('.nav-btn').forEach(function(b) { b.classList.remove('active'); });
    var navBtn = document.querySelector('.nav-btn[data-tab="' + tab + '"]');
    if (navBtn) navBtn.classList.add('active');
    var content = document.getElementById('content');
    var pages = { connection: getConnectionPageHTML(), settings: getSettingsPageHTML(), info: getInfoPageHTML(), logs: getLogsPageHTML() };
    content.innerHTML = pages[tab];
    if (tab === 'connection') {
        generateMoonStars();
        updateConfigList();
        updateSelectedConfigDisplay();
        updateMoonState();
        var btn = document.getElementById('moonBtn');
        if (btn) btn.disabled = !selectedConfigId && !isConnected;
    }
    if (tab === 'settings') loadSettings();
    if (tab === 'logs') {
        var container = document.getElementById('logsContainer');
        if (container && window._logBuffer) {
            container.textContent = window._logBuffer || '';
            container.scrollTop = container.scrollHeight;
        }
    }
}

function getConnectionPageHTML() {
    var html = '<div class="moon-container">';
    html += '<button class="moon-btn" id="moonBtn" onclick="toggleConnect()">';
    html += '<svg viewBox="0 0 100 100" width="130" height="130"><circle cx="50" cy="50" r="48" fill="#1a1a3e" stroke="#4a6cf7" stroke-width="2"/><path d="M60 18 A28 28 0 1 0 82 58 A34 34 0 1 1 60 18 Z" fill="#f7e84e" stroke="#d4c42a" stroke-width="1.5"/><circle cx="28" cy="30" r="2" fill="#4a6cf7" opacity="0.35"/><circle cx="74" cy="26" r="1.5" fill="#4a6cf7" opacity="0.25"/><circle cx="22" cy="70" r="1.8" fill="#4a6cf7" opacity="0.3"/><circle cx="78" cy="68" r="1.2" fill="#4a6cf7" opacity="0.2"/><circle cx="34" cy="76" r="1.5" fill="#4a6cf7" opacity="0.25"/></svg>';
    html += '</button><div class="moon-stars" id="moonStars"></div></div>';
    html += '<div id="statusText" class="status-text">' + (isConnected ? 'Подключено' : (selectedConfigId ? 'Готов к подключению' : 'Выберите конфиг')) + '</div>';
    html += '<div class="config-selector" id="configSelector">';
    html += '<div class="config-selector-header" onclick="toggleConfigDropdown()"><span id="selectedConfigName">' + getSelectedConfigName() + '</span><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2"><polyline points="6 9 12 15 18 9"/></svg></div>';
    html += '<div class="config-dropdown" id="configDropdown"><div id="configList"></div></div></div>';
    return html;
}

function getSettingsPageHTML() {
    var html = '<div style="width:100%;max-width:550px;margin:0 auto;"><div class="settings-scroll">';
    html += '<div class="settings-group"><div class="group-title open" onclick="toggleSettingsGroup(this)">Основные параметры<span class="arrow">v</span></div>';
    html += '<div class="group-body open">';
    html += '<div class="settings-row"><label>Peer</label><input type="text" id="peerInput" placeholder="203.0.113.10:46000" value="' + settings.peer + '"></div>';
    html += '<div class="settings-row"><label>Пароль</label><input type="password" id="passwordInput" style="flex:1;"></div>';
    html += '<div class="settings-row"><label>VK хеши</label><textarea id="hashesInput" rows="2">' + settings.vkHashes + '</textarea></div>';
    html += '<div class="settings-row"><label>Воркеров на хеш</label><input type="range" id="workersSlider" min="9" max="27" step="9" value="' + settings.workersPerHash + '" oninput="updateWorkers(this.value)"><input type="number" id="workersInput" min="9" max="27" step="9" value="' + settings.workersPerHash + '" onchange="updateWorkersFromInput(this.value)"><span class="hint">(кратно 9)</span></div>';
    html += '</div></div>';
    html += '<div class="settings-group"><div class="group-title" onclick="toggleSettingsGroup(this)">Дополнительные настройки<span class="arrow">v</span></div>';
    html += '<div class="group-body"><div class="settings-grid">';
    html += '<div class="settings-row"><label>TURN host</label><input type="text" id="turnHostInput" value="' + settings.turnHost + '"></div>';
    html += '<div class="settings-row"><label>TURN port</label><input type="text" id="turnPortInput" value="' + settings.turnPort + '"></div>';
    html += '<div class="settings-row"><label>Обфускация</label><select id="obfsSelect"><option value="video"' + (settings.obfs==='video'?' selected':'') + '>video</option><option value="audio"' + (settings.obfs==='audio'?' selected':'') + '>audio</option></select></div>';
    html += '<div class="settings-row"><label>TLS fingerprint</label><select id="fingerprintSelect"><option value="firefox"' + (settings.fingerprint==='firefox'?' selected':'') + '>firefox</option><option value="chrome"' + (settings.fingerprint==='chrome'?' selected':'') + '>chrome</option><option value="edge"' + (settings.fingerprint==='edge'?' selected':'') + '>edge</option><option value="safari"' + (settings.fingerprint==='safari'?' selected':'') + '>safari</option><option value="opera"' + (settings.fingerprint==='opera'?' selected':'') + '>opera</option></select></div>';
    html += '<div class="settings-row"><label>Client IDs</label><input type="text" id="clientIdsInput" value="' + settings.clientIds + '"></div>';
    html += '<div class="settings-row"><label>VK auth</label><select id="vkAuthSelect"><option value="vkcalls"' + (settings.vkAuthMode==='vkcalls'?' selected':'') + '>vkcalls</option><option value="legacy"' + (settings.vkAuthMode==='legacy'?' selected':'') + '>legacy</option></select></div>';
    html += '<div class="settings-row"><label>Captcha</label><select id="captchaSelect"><option value="auto"' + (settings.captchaMode==='auto'?' selected':'') + '>auto</option><option value="manual"' + (settings.captchaMode==='manual'?' selected':'') + '>manual</option></select></div>';
    html += '</div></div></div>';
    html += '<div class="settings-group"><div class="group-title" onclick="toggleSettingsGroup(this)">Системные<span class="arrow">v</span></div>';
    html += '<div class="group-body">';
    html += '<div class="settings-row"><label>Device ID</label><input type="text" id="deviceIdInput" value="' + (settings.deviceId||'') + '" style="flex:1;"><button class="btn-secondary" onclick="document.getElementById(\'deviceIdInput\').value=generateDeviceId();" style="padding:4px 12px;font-size:13px;">Сгенерировать</button></div>';
    html += '<div class="settings-row"><label class="toggle-label"><input type="checkbox" id="autoConnectCheck"' + (settings.autoConnect?' checked':'') + ' onchange="saveSettings()">Автоподключение при запуске</label></div>';
    html += '</div></div>';
    html += '<button class="btn-primary" onclick="saveSettings()" style="width:100%;margin-top:8px;">Сохранить настройки</button>';
    html += '</div></div>';
    return html;
}

function getInfoPageHTML() {
    return '<div class="info-title">LaLune</div><div class="info-sub">Кроссплатформенный клиент CSQTT</div>' +
        '<div class="info-block"><div class="label">Разработчики</div><div class="value">CSQTT - amurcanov</div><div class="value" style="margin-top:4px;">LaLune - Endlad7373</div></div>' +
        '<div class="info-block"><div class="label">Поддержать CSQTT</div><div class="value"><a href="https://yoomoney.ru/to/4100119505530465/100" target="_blank">YooMoney</a></div></div>' +
        '<div class="info-block"><div class="label">Поддержать LaLune</div><div class="value">2202208453630882 (Сбер)</div></div>' +
        '<div class="info-block"><div class="label">Версии</div><div class="value">CSQTT 2.0.5 - LaLune 0.4</div></div>';
}

function getLogsPageHTML() {
    return '<div class="logs-header"><h3>Журнал</h3><button class="btn-clear" onclick="clearLogs()"><svg viewBox="0 0 24 24" width="22" height="22"><path d="M3 6h18v2H3z" fill="#E67E22"/><path d="M5 8h14v1H5z" fill="#E67E22"/><path d="M8 3c0-1.5 8-1.5 8 0v2h-2V3.5c0-0.5-6-0.5-6 0V5H8z" fill="#E67E22"/><path d="M6 8l1.5 13h9L18 8H6z" fill="#F39C12" stroke="#E67E22" stroke-width="1"/><path d="M6 8l1.5 13h4V8H6z" fill="#E67E22" opacity="0.3"/><line x1="8" y1="12" x2="16" y2="12" stroke="#E67E22" stroke-width="0.8"/><line x1="8.5" y1="16" x2="15.5" y2="16" stroke="#E67E22" stroke-width="0.8"/></svg></button></div>' +
        '<div class="logs-container" id="logsContainer"></div>';
}

function getSelectedConfigName() {
    if (!selectedConfigId) return 'Нет конфига';
    for (var i = 0; i < configs.length; i++) {
        if (configs[i].id === selectedConfigId) return configs[i].name || configs[i].peer;
    }
    return 'Нет конфига';
}

function updateSelectedConfigDisplay() {
    var el = document.getElementById('selectedConfigName');
    if (el) el.textContent = getSelectedConfigName();
}

function toggleConfigDropdown() {
    var dd = document.getElementById('configDropdown');
    var h = document.querySelector('.config-selector-header');
    if (dd) { dd.classList.toggle('open'); if (h) h.classList.toggle('open'); }
}

function updateConfigList() {
    var container = document.getElementById('configList');
    if (!container) return;
    if (!configs || configs.length === 0) {
        container.innerHTML = '<div style="padding:16px;text-align:center;color:rgba(255,255,255,0.3);font-size:16px;">Нет сохранённых конфигов</div>';
        return;
    }
    var html = '';
    for (var i = 0; i < configs.length; i++) {
        var c = configs[i];
        var name = c.name || c.peer;
        html += '<div class="config-item' + (selectedConfigId===c.id?' selected':'') + '" onclick="selectConfig(' + c.id + ')">';
        html += '<span class="protocol-badge">' + c.protocol + '</span>';
        html += '<span class="config-name">' + name + '</span>';
        html += '<button class="delete-btn" onclick="event.stopPropagation();deleteConfig(' + c.id + ')">';
        html += '<svg viewBox="0 0 24 24" width="20" height="20"><path d="M3 6h18v2H3z" fill="#E67E22"/><path d="M5 8h14v1H5z" fill="#E67E22"/><path d="M8 3c0-1.5 8-1.5 8 0v2h-2V3.5c0-0.5-6-0.5-6 0V5H8z" fill="#E67E22"/><path d="M6 8l1.5 13h9L18 8H6z" fill="#F39C12" stroke="#E67E22" stroke-width="1"/><path d="M6 8l1.5 13h4V8H6z" fill="#E67E22" opacity="0.3"/><line x1="8" y1="12" x2="16" y2="12" stroke="#E67E22" stroke-width="0.8"/><line x1="8.5" y1="16" x2="15.5" y2="16" stroke="#E67E22" stroke-width="0.8"/></svg>';
        html += '</button></div>';
    }
    container.innerHTML = html;
}

function selectConfig(id) {
    selectedConfigId = id;
    updateConfigList();
    updateSelectedConfigDisplay();
    toggleConfigDropdown();
    updateMoonState();
}

function updateMoonState() {
    var btn = document.getElementById('moonBtn');
    var status = document.getElementById('statusText');
    if (btn) btn.disabled = !selectedConfigId && !isConnected;
    if (status) {
        if (isConnected) status.textContent = 'Подключено';
        else if (selectedConfigId) {
            var name = 'Готов к подключению';
            for (var i = 0; i < configs.length; i++) {
                if (configs[i].id === selectedConfigId) name = 'Готов к подключению: ' + (configs[i].name || configs[i].peer);
            }
            status.textContent = name;
        } else status.textContent = 'Выберите конфиг';
    }
}

function toggleConnect() {
    if (!api) { showToast('API не подключен'); return; }
    if (isConnected) { api.disconnect(); return; }
    if (!selectedConfigId) { showToast('Выберите конфиг'); return; }
    api.connect(selectedConfigId);
}

function setConnected(state) {
    isConnected = state;
    updateMoonState();
    var stars = document.getElementById('moonStars');
    if (stars) stars.classList.toggle('active', state);
    var btn = document.getElementById('moonBtn');
    if (btn) btn.disabled = false;
    var status = document.getElementById('statusText');
    if (status) status.textContent = state ? 'Подключено' : (selectedConfigId ? 'Готов к подключению' : 'Выберите конфиг');
}

function showAddModal() {
    document.getElementById('addModal').classList.add('open');
    document.getElementById('configInput').value = '';
}

function closeAddModal() {
    document.getElementById('addModal').classList.remove('open');
}

function setImportMethod(method) {
    importMethod = method;
    document.querySelectorAll('.import-btn').forEach(function(b) { b.classList.remove('active'); });
    var btns = document.querySelectorAll('.import-btn');
    btns[method === 'manual' ? 0 : 1].classList.add('active');
    if (method === 'clipboard') {
        navigator.clipboard.readText().then(function(text) {
            document.getElementById('configInput').value = text;
        }).catch(function() {
            showToast('Не удалось прочитать буфер обмена');
        });
    }
}

function saveConfig() {
    var input = document.getElementById('configInput');
    var link = input.value.trim();
    if (!link) { showToast('Введите ссылку'); return; }
    if (link.indexOf('csqtt://') !== 0) { showToast('Неверный формат ссылки'); return; }
    if (!api) { showToast('API не подключен'); return; }
    api.saveConfig(link).then(function(result) {
        closeAddModal();
        if (result) {
            showToast('Конфиг сохранён');
        } else {
            showToast('Ошибка сохранения');
        }
    });
}

function deleteConfig(id) {
    if (!api) { showToast('API не подключен'); return; }
    if (!confirm('Удалить конфиг?')) return;
    api.deleteConfig(id);
}

function refreshConfigs(json) {
    try {
        configs = JSON.parse(json);
        updateConfigList();
        updateSelectedConfigDisplay();
        updateMoonState();
    } catch(e) {
        console.error('refreshConfigs error:', e);
    }
}

function refreshSettings(json) {
    try {
        settings = JSON.parse(json);
        var deviceInput = document.getElementById('deviceIdInput');
        if (deviceInput) deviceInput.value = settings.deviceId || '';
    } catch(e) {
        console.error('refreshSettings error:', e);
    }
}

function appendLog(line) {
    var container = document.getElementById('logsContainer');
    if (!container) { if (!window._logBuffer) window._logBuffer = ''; window._logBuffer += line + '\n'; return; }
    container.textContent += line + '\n';
    container.scrollTop = container.scrollHeight;
}

function clearLogs() {
    window._logBuffer = '';
    var container = document.getElementById('logsContainer');
    if (container) container.textContent = '';
    if (api) api.clearLogs();
}

function showToast(msg) {
    var el = document.getElementById('toast');
    if (!el) return;
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(el._timeout);
    el._timeout = setTimeout(function() { el.classList.remove('show'); }, 3000);
}

function toggleSettingsGroup(el) {
    var body = el.parentElement.querySelector('.group-body');
    if (body) { body.classList.toggle('open'); el.classList.toggle('open'); }
}

function loadSettings() {
    var fields = {
        peerInput: settings.peer,
        passwordInput: '',
        hashesInput: settings.vkHashes,
        workersSlider: settings.workersPerHash,
        workersInput: settings.workersPerHash,
        turnHostInput: settings.turnHost,
        turnPortInput: settings.turnPort,
        obfsSelect: settings.obfs,
        fingerprintSelect: settings.fingerprint,
        clientIdsInput: settings.clientIds,
        vkAuthSelect: settings.vkAuthMode,
        captchaSelect: settings.captchaMode,
        deviceIdInput: settings.deviceId || ''
    };
    for (var id in fields) {
        var el = document.getElementById(id);
        if (el) {
            if (el.tagName === 'SELECT') {
                for (var i = 0; i < el.options.length; i++) {
                    if (el.options[i].value === fields[id]) { el.options[i].selected = true; break; }
                }
            } else {
                el.value = fields[id];
            }
        }
    }
    var autoCheck = document.getElementById('autoConnectCheck');
    if (autoCheck) autoCheck.checked = settings.autoConnect || false;
}

function saveSettings() {
    if (!api) { showToast('API не подключен'); return; }
    var peer = document.getElementById('peerInput');
    var password = document.getElementById('passwordInput');
    var hashes = document.getElementById('hashesInput');
    var workers = document.getElementById('workersInput');
    var turnHost = document.getElementById('turnHostInput');
    var turnPort = document.getElementById('turnPortInput');
    var obfs = document.getElementById('obfsSelect');
    var fingerprint = document.getElementById('fingerprintSelect');
    var clientIds = document.getElementById('clientIdsInput');
    var vkAuth = document.getElementById('vkAuthSelect');
    var captcha = document.getElementById('captchaSelect');
    var deviceId = document.getElementById('deviceIdInput');
    var autoConnect = document.getElementById('autoConnectCheck');
    settings.peer = peer ? peer.value : '';
    settings.vkHashes = hashes ? hashes.value : '';
    settings.turnHost = turnHost ? turnHost.value : '';
    settings.turnPort = turnPort ? turnPort.value : '';
    settings.workersPerHash = workers ? parseInt(workers.value) || 9 : 9;
    settings.obfs = obfs ? obfs.value : 'video';
    settings.fingerprint = fingerprint ? fingerprint.value : 'firefox';
    settings.clientIds = clientIds ? clientIds.value : '8202606,6287487';
    settings.vkAuthMode = vkAuth ? vkAuth.value : 'vkcalls';
    settings.captchaMode = captcha ? captcha.value : 'auto';
    var deviceValue = deviceId ? deviceId.value.trim() : '';
    if (deviceValue && deviceValue !== 'auto') {
        settings.deviceId = deviceValue;
    }
    settings.autoConnect = autoConnect ? autoConnect.checked : false;
    if (password && password.value) api.savePassword(password.value);
    api.saveSettings(JSON.stringify(settings));
    showToast('Настройки сохранены');
}

function updateWorkers(val) {
    var input = document.getElementById('workersInput');
    if (input) input.value = val;
    settings.workersPerHash = parseInt(val);
}

function updateWorkersFromInput(val) {
    var v = parseInt(val);
    if (isNaN(v)) v = 9;
    v = Math.max(9, Math.min(27, v));
    v = Math.round(v/9)*9;
    if (v < 9) v = 9;
    var slider = document.getElementById('workersSlider');
    if (slider) slider.value = v;
    var input = document.getElementById('workersInput');
    if (input) input.value = v;
    settings.workersPerHash = v;
}

function generateDeviceId() {
    var id = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'.replace(/x/g, function() {
        return Math.floor(Math.random()*16).toString(16);
    });
    var input = document.getElementById('deviceIdInput');
    if (input) input.value = id;
    settings.deviceId = id;
}

function showUpdateBanner(version) {
    var banner = document.getElementById('updateBanner');
    if (!banner) return;
    banner.innerHTML = '<span>Доступна новая версия ядра: ' + version + '</span><button onclick="updateCore()">Обновить</button>';
    banner.classList.add('show');
}

function updateCore() {
    if (!api) { showToast('API не подключен'); return; }
    if (isConnected) { showToast('Сначала отключитесь'); return; }
    api.updateCore();
    var banner = document.getElementById('updateBanner');
    if (banner) banner.classList.remove('show');
    showToast('Обновление запущено');
}

function initApp() {
    generateStars();
    switchTab('connection');
    
    if (typeof qt !== 'undefined' && qt.webChannelTransport) {
        new QWebChannel(qt.webChannelTransport, function(channel) {
            api = channel.objects.api;
            
            api.getConfigsJson().then(function(configsJson) {
                configs = JSON.parse(configsJson);
                if (configs.length > 0) selectedConfigId = configs[0].id;
                updateConfigList();
                updateSelectedConfigDisplay();
                updateMoonState();
            }).catch(function(e) {
                console.error('Init configs error:', e);
            });
            
            api.getSettingsJson().then(function(settingsJson) {
                settings = JSON.parse(settingsJson);
                var deviceInput = document.getElementById('deviceIdInput');
                if (deviceInput) deviceInput.value = settings.deviceId || '';
            }).catch(function(e) {
                console.error('Init settings error:', e);
            });
        });
    }
    
    document.addEventListener('click', function(e) {
        var sel = document.getElementById('configSelector');
        if (sel && !sel.contains(e.target)) {
            var dd = document.getElementById('configDropdown');
            var h = document.querySelector('.config-selector-header');
            if (dd) dd.classList.remove('open');
            if (h) h.classList.remove('open');
        }
    });
    
    document.addEventListener('keydown', function(e) {
        if (e.key === 'Escape') closeAddModal();
    });
}

document.addEventListener('DOMContentLoaded', function() {
    initApp();
});
