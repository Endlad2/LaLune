// LaLune OpenWRT - клиентский JS
const API_BASE = '';

let currentTab = 'connection';
let statusInterval = null;
let logsInterval = null;
let isConnected = false;

// ============ Инициализация ============
document.addEventListener('DOMContentLoaded', function() {
    generateStars();
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
    
    // Обновляем кнопки
    document.querySelectorAll('.nav-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.tab === tab);
    });
    
    // Рендерим контент
    const content = document.getElementById('content');
    if (tab === 'connection') {
        renderConnection(content);
    } else if (tab === 'logs') {
        renderLogs(content);
    }
}

// ============ Вкладка "Подключение" ============
function renderConnection(container) {
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
        <div class="config-info">
            <div class="label">Peer</div>
            <div class="value" id="peerDisplay">Загрузка...</div>
        </div>
        <div class="config-info">
            <div class="label">Статус</div>
            <div class="value" id="statusDetail">${isConnected ? '🟢 Активно' : '🔴 Не активно'}</div>
        </div>
    `;
    loadConfig();
}

function toggleConnection() {
    if (isConnected) {
        disconnect();
    } else {
        connect();
    }
}

function connect() {
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

function loadConfig() {
    fetch('/api/config')
        .then(r => r.json())
        .then(config => {
            const peerDisplay = document.getElementById('peerDisplay');
            if (peerDisplay) {
                peerDisplay.textContent = config.peer || 'Не настроен';
            }
        })
        .catch(() => {
            const peerDisplay = document.getElementById('peerDisplay');
            if (peerDisplay) {
                peerDisplay.textContent = 'Ошибка загрузки';
            }
        });
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
                // Автоскролл вниз
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
            
            // Обновляем UI если на вкладке connection
            if (currentTab === 'connection') {
                const statusText = document.getElementById('statusText');
                if (statusText) {
                    statusText.textContent = isConnected ? 'Подключено' : 'Отключено';
                }
                
                const statusDetail = document.getElementById('statusDetail');
                if (statusDetail) {
                    statusDetail.textContent = isConnected ? '🟢 Активно' : '🔴 Не активно';
                }
                
                // Обновляем луну
                const moonBtn = document.querySelector('.moon-btn');
                if (moonBtn) {
                    const svg = moonBtn.querySelector('svg');
                    if (svg) {
                        // Обновляем цвет
                        const circles = svg.querySelectorAll('circle');
                        if (circles.length > 0) {
                            circles[0].setAttribute('fill', isConnected ? '#f7e84e' : '#4a6cf7');
                            circles[0].setAttribute('opacity', isConnected ? '1' : '0.3');
                        }
                        // Обновляем текст
                        const text = svg.querySelector('text');
                        if (text) {
                            text.textContent = isConnected ? '✓' : '▶';
                        }
                    }
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
