// LaLune OpenWRT - клиентский JS
const API_BASE = '';

let currentTab = 'connection';
let statusInterval = null;
let logsInterval = null;
let isConnected = false;
let configs = [];
let selectedConfigId = null;
let settings = {};

// ============ Инициализация ============
document.addEventListener('DOMContentLoaded', function() {
    generateStars();
    loadConfigs();
    loadSettings();
    switchTab('connection');
    startStatusPolling();
    startLogsPolling();
});

// ============ Звёзды ============
function generateStars() {
    const container = document.getElementById('stars');
    for (let i = 0; i < 80; i++) {
        const star = document.createElement('div');
        star.className = 'star';
        const size = Math.random() * 2 + 1;
        star.style.width = size + 'px';
        star.style.height = size + 'px';
        star.style.left = Math.random() * 100 + '%';
        star.style.top = Math.random() * 100 + '%';
        star.style.opacity = Math.random() * 0.8 + 0.2;
        container.appendChild(star);
    }
}

// ============ Переключение вкладок ============
function switchTab(tab) {
    currentTab = tab;
    
    document.querySelectorAll('.nav-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.tab === tab);
    });
    
    const content = document.getElementById('content');
    if (tab === 'connection') {
        renderConnection(content);
    } else if (tab === 'settings') {
        renderSettings(content);
    } else if (tab === 'info') {
        renderInfo(content);
    } else if (tab === 'logs') {
        renderLogs(content);
    }
}

// ============ Вкладка "Подключение" ============
function renderConnection(container) {
    const selected = configs.find(c => c.id === selectedConfigId);
    const name = selected ? selected.name || selected.peer : 'Выберите конфиг';
    
    container.innerHTML = `
        <div class="moon-container">
            <button class="moon-btn" onclick="toggleConnection()">
                <svg viewBox="0 0 120 120" width="110" height="110">
                    <circle cx="60" cy="60" r="50" fill="${isConnected ? '#f7e84e' : '#4a6cf7'}" opacity="${isConnected ? '1' : '0.3'}"/>
                    <circle cx="60" cy="60" r="50" fill="none" stroke="rgba(255,255,255,0.1)" stroke-width="2"/>
                    ${isConnected ? `
                        <circle cx="60" cy="60" r="35" fill="none" stroke="#f7e84e" stroke-width="2" stroke-dasharray="8 4"/>
                        <circle cx="60" cy="60" r="20" fill="none" stroke="#f7e84e" stroke-width="2" opacity="0.5"/>
                    ` : ''}
                    <text x="60" y="66" text-anchor="middle" fill="white" font-size="14" font-weight="700">
                        ${isConnected ? '✓' : '▶'}
                    </text>
                </svg>
            </button>
        </div>
        <div class="status-text" id="statusText">${isConnected ? 'Подключено' : 'Отключено'}</div>
        <div class="config-selector">
            <div class="config-selector-header" onclick="toggleDropdown()">
                <span id="selectedConfigName">${name}</span>
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.5)" stroke-width="2">
                    <polyline points="6 9 12 15 18 9"/>
                </svg>
            </div>
            <div class="config-dropdown" id="configDropdown">
                ${configs.map(c => `
                    <div class="config-item" onclick="selectConfig(${c.id})">
                        <span class="protocol-badge">${c.protocol || 'CSQTT'}</span>
                        <span class="config-name">${c.name || c.peer}</span>
                    </div>
                `).join('')}
                ${configs.length === 0 ? '<div class="config-item" style="color:rgba(255,255,255,0.3);justify-content:center;">Нет конфигов</div>' : ''}
            </div>
        </div>
    `;
}

function toggleDropdown() {
    document.getElementById('configDropdown').classList.toggle('open');
}

function selectConfig(id) {
    selectedConfigId = id;
    document.getElementById('configDropdown').classList.remove('open');
    renderConnection(document.getElementById('content'));
}

function toggleConnection() {
    if (isConnected) {
        disconnect();
    } else {
        connect();
    }
}

function connect() {
    if (!selectedConfigId) {
        showToast('Выберите конфиг');
        return;
    }
    showToast('Подключение...');
    fetch('/api/connect', { method: 'POST' })
        .then(r => r.json())
        .then(data => {
            if (data.success) {
                showToast('Подключено');
                updateStatus();
            } else {
                showToast('Ошибка подключения');
            }
        })
        .catch(() => showToast('Ошибка запроса'));
}

function disconnect() {
    showToast('Отключение...');
    fetch('/api/disconnect', { method: 'POST' })
        .then(r => r.json())
        .then(data => {
            if (data.success) {
                showToast('Отключено');
                updateStatus();
            } else {
                showToast('Ошибка отключения');
            }
        })
        .catch(() => showToast('Ошибка запроса'));
}

// ============ Вкладка "Настройки" ============
function renderSettings(container) {
    container.innerHTML = `
        <div class="settings-scroll">
            <div class="settings-group">
                <div class="settings-row">
                    <label>Peer</label>
                    <input type="text" id="settingsPeer" value="${settings.peer || ''}" placeholder="host:port">
                </div>
                <div class="settings-row">
                    <label>Password</label>
                    <input type="text" id="settingsPassword" value="${settings.password || ''}" placeholder="Пароль">
                </div>
                <div class="settings-row">
                    <label>Hashes</label>
                    <input type="text" id="settingsHashes" value="${settings.vkHashes || ''}" placeholder="hash1,hash2">
                </div>
                <div class="settings-row">
                    <label>TUN</label>
                    <input type="text" id="settingsTun" value="${settings.tun || 'csqtt0'}" placeholder="Имя TUN">
                </div>
                <div class="settings-row">
                    <label>Workers</label>
                    <input type="number" id="settingsWorkers" value="${settings.workers || 9}" min="1">
                </div>
                <button class="btn-primary" onclick="saveSettings()" style="width:100%;margin-top:8px;">Сохранить настройки</button>
            </div>
        </div>
    `;
}

function saveSettings() {
    const newSettings = {
        peer: document.getElementById('settingsPeer').value,
        password: document.getElementById('settingsPassword').value,
        vkHashes: document.getElementById('settingsHashes').value,
        tun: document.getElementById('settingsTun').value || 'csqtt0',
        workers: parseInt(document.getElementById('settingsWorkers').value) || 9
    };
    
    fetch('/api/config/update', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(newSettings)
    })
    .then(r => r.json())
    .then(data => {
        if (data.success) {
            settings = newSettings;
            showToast('Настройки сохранены');
        } else {
            showToast('Ошибка сохранения');
        }
    })
    .catch(() => showToast('Ошибка запроса'));
}

// ============ Вкладка "Информация" ============
function renderInfo(container) {
    container.innerHTML = `
        <div class="info-title">🌙 LaLune</div>
        <div class="info-sub">OpenWRT VPN клиент</div>
        <div class="info-block">
            <div class="label">Версия</div>
            <div class="value">0.6.0</div>
        </div>
        <div class="info-block">
            <div class="label">Статус</div>
            <div class="value" id="infoStatus">${isConnected ? '🟢 Подключено' : '🔴 Отключено'}</div>
        </div>
        <div class="info-block">
            <div class="label">Конфигов</div>
            <div class="value">${configs.length}</div>
        </div>
        <div class="info-block">
            <div class="label">Протокол</div>
            <div class="value">CSQTT</div>
        </div>
    `;
}

// ============ Вкладка "Логи" ============
function renderLogs(container) {
    container.innerHTML = `
        <div class="logs-container" id="logsContainer">
            <div class="logs-header">
                <h3>📋 Логи</h3>
                <button class="btn-clear" onclick="clearLogs()">Очистить</button>
            </div>
            <div id="logsContent" style="font-size:12px;line-height:1.6;white-space:pre-wrap;word-wrap:break-word;font-family:monospace;">
                Загрузка логов...
            </div>
        </div>
    `;
    fetchLogs();
}

function fetchLogs() {
    fetch('/api/logs')
        .then(r => r.text())
        .then(text => {
            const content = document.getElementById('logsContent');
            if (content) {
                content.textContent = text || 'Логов пока нет';
                const container = document.getElementById('logsContainer');
                if (container) {
                    container.scrollTop = container.scrollHeight;
                }
            }
        })
        .catch(() => {
            const content = document.getElementById('logsContent');
            if (content) {
                content.textContent = 'Ошибка загрузки логов';
            }
        });
}

function clearLogs() {
    showToast('Логи очищены');
    // На сервере нет эндпоинта для очистки, просто обновляем
    fetchLogs();
}

// ============ Конфиги ============
function loadConfigs() {
    fetch('/api/config')
        .then(r => r.json())
        .then(data => {
            // Преобразуем из формата OpenWRT в массив конфигов
            if (data.peer) {
                configs = [{
                    id: 1,
                    protocol: 'CSQTT',
                    peer: data.peer,
                    password: data.password,
                    hashes: data.vkHashes,
                    name: data.peer
                }];
            } else {
                configs = [];
            }
            if (configs.length > 0) {
                selectedConfigId = configs[0].id;
            }
            // Перерисовываем текущую вкладку
            if (currentTab === 'connection') {
                renderConnection(document.getElementById('content'));
            }
        })
        .catch(() => {});
}

function loadSettings() {
    fetch('/api/config')
        .then(r => r.json())
        .then(data => {
            settings = {
                peer: data.peer || '',
                password: data.password || '',
                vkHashes: data.vkHashes || '',
                tun: data.tun || 'csqtt0',
                workers: data.workers || 9
            };
            if (currentTab === 'settings') {
                renderSettings(document.getElementById('content'));
            }
        })
        .catch(() => {});
}

// ============ Модалка добавления конфига ============
function showAddModal() {
    document.getElementById('addModal').classList.add('open');
    document.getElementById('configInput').value = '';
}

function closeAddModal() {
    document.getElementById('addModal').classList.remove('open');
}

function saveConfig() {
    const link = document.getElementById('configInput').value.trim();
    if (!link) {
        showToast('Введите ссылку');
        return;
    }
    
    // Парсим ссылку на клиенте (просто для отображения)
    const config = parseCsqttLink(link);
    
    // Отправляем на сервер
    fetch('/api/config/update', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            peer: config.peer,
            password: config.password,
            vkHashes: config.hashes,
            tun: settings.tun || 'csqtt0',
            workers: settings.workers || 9
        })
    })
    .then(r => r.json())
    .then(data => {
        if (data.success) {
            showToast('Конфиг сохранён');
            closeAddModal();
            loadConfigs();
            loadSettings();
        } else {
            showToast('Ошибка сохранения');
        }
    })
    .catch(() => showToast('Ошибка запроса'));
}

function parseCsqttLink(link) {
    let peer = link;
    let password = '';
    let hashes = '';
    
    if (link.startsWith('csqtt://')) {
        try {
            const url = new URL(link);
            if (url.hostname === 'connect') {
                const params = new URLSearchParams(url.search);
                const host = params.get('host') || '';
                const port = params.get('peer') || '';
                password = params.get('password') || '';
                hashes = (params.get('hashes') || '').replace(/\+/g, ',');
                peer = `${host}:${port}`;
            } else {
                const host = url.hostname;
                const port = url.port || '46000';
                password = url.username || '';
                peer = `${host}:${port}`;
            }
        } catch (e) {}
    }
    
    return { peer, password, hashes };
}

// ============ Периодические обновления ============
function startStatusPolling() {
    if (statusInterval) clearInterval(statusInterval);
    statusInterval = setInterval(updateStatus, 3000);
    updateStatus();
}

function startLogsPolling() {
    if (logsInterval) clearInterval(logsInterval);
    logsInterval = setInterval(() => {
        if (currentTab === 'logs') {
            fetchLogs();
        }
    }, 5000);
}

function updateStatus() {
    fetch('/api/status')
        .then(r => r.json())
        .then(data => {
            isConnected = data.connected || false;
            
            if (currentTab === 'connection') {
                const statusText = document.getElementById('statusText');
                if (statusText) {
                    statusText.textContent = isConnected ? 'Подключено' : 'Отключено';
                }
                const moonBtn = document.querySelector('.moon-btn');
                if (moonBtn) {
                    const svg = moonBtn.querySelector('svg');
                    if (svg) {
                        const circles = svg.querySelectorAll('circle');
                        if (circles.length > 0) {
                            circles[0].setAttribute('fill', isConnected ? '#f7e84e' : '#4a6cf7');
                            circles[0].setAttribute('opacity', isConnected ? '1' : '0.3');
                        }
                        const text = svg.querySelector('text');
                        if (text) {
                            text.textContent = isConnected ? '✓' : '▶';
                        }
                    }
                }
            }
            
            if (currentTab === 'info') {
                const statusEl = document.getElementById('infoStatus');
                if (statusEl) {
                    statusEl.textContent = isConnected ? '🟢 Подключено' : '🔴 Отключено';
                }
            }
        })
        .catch(() => {});
}

// ============ Toast ============
function showToast(message) {
    const toast = document.getElementById('toast');
    toast.textContent = message;
    toast.classList.add('show');
    clearTimeout(toast._timeout);
    toast._timeout = setTimeout(() => {
        toast.classList.remove('show');
    }, 3000);
}
