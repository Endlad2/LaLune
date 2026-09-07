// Android Bridge для LaLune

if (typeof window._lalune_loaded === 'undefined') {
    window._lalune_loaded = true;

    let currentConfigs = [];
    let selectedConfigId = null;
    let isConnected = false;
    let currentTab = 'connection';
    let currentSettings = {
        peer: '',
        vkHashes: '',
        password: '',
        workersPerHash: 9
    };

    function callNative(method, params) {
        return new Promise(function(resolve) {
            try {
                const result = window.lalune[method](...(params || []));
                resolve(result);
            } catch(e) {
                resolve('false');
            }
        });
    }

    document.addEventListener('DOMContentLoaded', function() {
        createStars();
        loadConfigs();
        startPolling();
        switchTab('connection');
    });

    function startPolling() {
        setInterval(function() {
            callNative('getStatus', []).then(function(result) {
                try {
                    const status = JSON.parse(result);
                    if (status.connected !== isConnected) {
                        setConnected(status.connected);
                    }
                } catch(e) {}
            });
        }, 2000);

        setInterval(function() {
            if (currentTab === 'logs') {
                loadLogs();
            }
        }, 2000);
    }

    function createStars() {
        const container = document.getElementById('stars');
        if (!container) return;
        for (let i = 0; i < 150; i++) {
            const star = document.createElement('div');
            star.className = 'star';
            const size = Math.random() * 3 + 1;
            star.style.width = size + 'px';
            star.style.height = size + 'px';
            star.style.left = Math.random() * 100 + '%';
            star.style.top = Math.random() * 100 + '%';
            star.style.opacity = Math.random() * 0.8 + 0.2;
            container.appendChild(star);
        }
    }

    function loadConfigs() {
        callNative('getConfigs', []).then(function(result) {
            try {
                currentConfigs = JSON.parse(result);
                renderConfigs();
            } catch(e) {}
        });
    }

    function renderConfigs() {
        const dropdown = document.getElementById('configDropdown');
        if (!dropdown) return;
        dropdown.innerHTML = '';
        if (currentConfigs.length === 0) {
            dropdown.innerHTML = '<div class="config-item">Нет конфигов</div>';
            return;
        }
        currentConfigs.forEach(function(config) {
            const item = document.createElement('div');
            item.className = 'config-item';
            if (selectedConfigId === config.id) item.classList.add('selected');
            item.innerHTML = '<span class="protocol-badge">CSQTT</span><span class="config-name">' + (config.name || config.peer) + '</span>';
            item.onclick = function() { selectConfig(config.id); };
            dropdown.appendChild(item);
        });
        updateSelectedConfigName();
    }

    function updateSelectedConfigName() {
        const nameSpan = document.getElementById('selectedConfigName');
        if (!nameSpan) return;
        const config = currentConfigs.find(c => c.id === selectedConfigId);
        nameSpan.textContent = config ? (config.name || config.peer) : 'Выберите конфиг';
    }

    function toggleConfigDropdown() {
        const dropdown = document.getElementById('configDropdown');
        if (dropdown) dropdown.classList.toggle('open');
    }

    function selectConfig(id) {
        selectedConfigId = id;
        const config = currentConfigs.find(c => c.id === id);
        if (config) {
            currentSettings.peer = config.peer || '';
            currentSettings.vkHashes = config.hashes || '';
            currentSettings.password = config.password || '';
        }
        updateSelectedConfigName();
        const dropdown = document.getElementById('configDropdown');
        if (dropdown) dropdown.classList.remove('open');
    }

    function saveConfig() {
        const input = document.getElementById('configInput');
        if (!input || !input.value.trim()) return;
        callNative('saveConfig', [input.value.trim()]).then(function(result) {
            if (result === true || result === 'true') {
                closeAddModal();
                loadConfigs();
                showToast('Конфиг сохранен');
            }
        });
    }

    function deleteConfig(id) {
        callNative('deleteConfig', [id]).then(function() {
            loadConfigs();
        });
    }

    function toggleConnect() {
        if (isConnected) {
            disconnect();
        } else {
            connect();
        }
    }

    function connect() {
        if (selectedConfigId === null) {
            showToast('Выберите конфиг');
            return;
        }
        callNative('connect', [selectedConfigId]).then(function(result) {
            if (result === true || result === 'true') {
                showToast('Подключение...');
            } else {
                showToast('Ошибка подключения');
            }
        });
    }

    function disconnect() {
        callNative('disconnect', []).then(function() {
            showToast('Отключено');
        });
    }

    function setConnected(connected) {
        isConnected = connected;
        const statusText = document.getElementById('statusText');
        if (statusText) statusText.textContent = connected ? 'Подключено' : 'Отключено';
    }

    function loadLogs() {
        callNative('getLogs', []).then(function(result) {
            try {
                const logs = JSON.parse(result);
                const content = document.getElementById('logsContent');
                if (content) content.textContent = logs.join('\n');
            } catch(e) {}
        });
    }

    function clearLogs() {
        callNative('clearLogs', []).then(function() {
            const content = document.getElementById('logsContent');
            if (content) content.textContent = 'Логи очищены';
        });
    }

    function switchTab(tab) {
        currentTab = tab;
        document.querySelectorAll('.nav-btn').forEach(function(btn) {
            btn.classList.remove('active');
            if (btn.dataset.tab === tab) btn.classList.add('active');
        });

        const container = document.getElementById('content');
        if (!container) return;
        container.innerHTML = '';

        if (tab === 'connection') {
            renderConnectionTab(container);
        } else if (tab === 'logs') {
            renderLogsTab(container);
        } else if (tab === 'settings') {
            renderSettingsTab(container);
        } else if (tab === 'info') {
            renderInfoTab(container);
        }
    }

    function renderConnectionTab(container) {
        container.innerHTML = `
            <div class="moon-container">
                <button class="moon-btn" onclick="toggleConnect()">
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
                        <circle cx="50" cy="50" r="48" fill="#1a1a3e" stroke="#4a6cf7" stroke-width="2"/>
                        <path d="M 60 18 A 28 28 0 1 0 82 58 A 34 34 0 1 1 60 18 Z" fill="#f7e84e" stroke="#d4c42a" stroke-width="1.5"/>
                    </svg>
                </button>
            </div>
            <div class="status-text" id="statusText">${isConnected ? 'Подключено' : 'Отключено'}</div>
            <div class="config-selector">
                <div class="config-selector-header" onclick="toggleConfigDropdown()">
                    <span id="selectedConfigName">Выберите конфиг</span>
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2"><polyline points="6 9 12 15 18 9"/></svg>
                </div>
                <div class="config-dropdown" id="configDropdown"></div>
            </div>
        `;
        renderConfigs();
    }

    function renderLogsTab(container) {
        container.innerHTML = `
            <div class="logs-container">
                <div class="logs-header">
                    <h3>Логи</h3>
                    <button class="btn-clear" onclick="clearLogs()">Очистить</button>
                </div>
                <div id="logsContent">Загрузка...</div>
            </div>
        `;
        loadLogs();
    }

    function renderSettingsTab(container) {
        container.innerHTML = `
            <div class="settings-scroll">
                <div class="settings-group">
                    <div class="group-title open">Основные настройки</div>
                    <div class="group-body open">
                        <div class="settings-row"><label>Peer</label><input type="text" id="settingPeer" value="${currentSettings.peer}"></div>
                        <div class="settings-row"><label>VK Hashes</label><input type="text" id="settingVkHashes" value="${currentSettings.vkHashes}"></div>
                        <div class="settings-row"><label>Password</label><input type="password" id="settingPassword" value="${currentSettings.password}"></div>
                        <div class="settings-row"><label>Workers</label><input type="number" id="settingWorkers" value="${currentSettings.workersPerHash}"></div>
                    </div>
                </div>
                <button class="btn-primary" onclick="saveSettings()">Сохранить</button>
            </div>
        `;
    }

    function saveSettings() {
        currentSettings.peer = document.getElementById('settingPeer')?.value || '';
        currentSettings.vkHashes = document.getElementById('settingVkHashes')?.value || '';
        currentSettings.password = document.getElementById('settingPassword')?.value || '';
        currentSettings.workersPerHash = parseInt(document.getElementById('settingWorkers')?.value) || 9;

        const settings = JSON.stringify({
            peer: currentSettings.peer,
            vkHashes: currentSettings.vkHashes,
            workersPerHash: currentSettings.workersPerHash,
            password: currentSettings.password
        });

        callNative('saveSettings', [settings]).then(function() {
            showToast('Настройки сохранены');
        });
    }

    function renderInfoTab(container) {
        container.innerHTML = `
            <div class="info-title">LaLune</div>
            <div class="info-sub">Android Client v0.5.0</div>
            <div class="info-block"><div class="label">Версия ядра</div><div class="value">2.1.9</div></div>
        `;
    }

    function showAddModal() {
        document.getElementById('addModal').classList.add('open');
    }

    function closeAddModal() {
        document.getElementById('addModal').classList.remove('open');
    }

    function setImportMethod(method) {
        document.querySelectorAll('.import-btn').forEach(function(btn) {
            btn.classList.remove('active');
        });
        event.target.classList.add('active');
    }

    function showToast(message) {
        const toast = document.getElementById('toast');
        if (!toast) return;
        toast.textContent = message;
        toast.classList.add('show');
        setTimeout(function() { toast.classList.remove('show'); }, 3000);
    }

    window.toggleConnect = toggleConnect;
    window.connect = connect;
    window.disconnect = disconnect;
    window.selectConfig = selectConfig;
    window.deleteConfig = deleteConfig;
    window.saveConfig = saveConfig;
    window.clearLogs = clearLogs;
    window.switchTab = switchTab;
    window.saveSettings = saveSettings;
    window.showAddModal = showAddModal;
    window.closeAddModal = closeAddModal;
    window.setImportMethod = setImportMethod;
    window.toggleConfigDropdown = toggleConfigDropdown;
}
