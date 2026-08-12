let currentTheme = 'dark';
let configs = JSON.parse(localStorage.getItem('wdtt_configs') || '[]');
let selectedConfig = null;
let isConnected = false;

document.addEventListener('DOMContentLoaded', function() {
    loadConfigs();
    switchTab('connect');
});

function toggleTheme() {
    currentTheme = currentTheme === 'dark' ? 'light' : 'dark';
    document.body.classList.toggle('light-mode', currentTheme === 'light');
    localStorage.setItem('wdtt_theme', currentTheme);
}

function loadTheme() {
    const saved = localStorage.getItem('wdtt_theme');
    if (saved) {
        currentTheme = saved;
        document.body.classList.toggle('light-mode', currentTheme === 'light');
    }
}

function switchTab(tab) {
    document.querySelectorAll('.tab-content').forEach(el => el.classList.remove('active'));
    document.querySelectorAll('.nav-btn').forEach(el => el.classList.remove('active'));
    
    const content = document.getElementById('tab-' + tab);
    if (content) content.classList.add('active');
    
    const btn = document.querySelector(`[data-tab="${tab}"]`);
    if (btn) btn.classList.add('active');
}

function toggleConfigMenu() {
    document.getElementById('configDropdown').classList.toggle('show');
}

function loadConfigs() {
    const list = document.getElementById('configList');
    list.innerHTML = '';
    configs.forEach((cfg, idx) => {
        const li = document.createElement('li');
        li.textContent = cfg.name || cfg.serverIP || 'Config ' + (idx + 1);
        li.onclick = () => selectConfig(idx);
        list.appendChild(li);
    });
}

function selectConfig(idx) {
    selectedConfig = configs[idx];
    document.getElementById('configDropdown').classList.remove('show');
    document.getElementById('connectBtn').style.opacity = '1';
    document.getElementById('connectBtn').querySelector('span').textContent = 'Подключить';
}

function showAddDialog() {
    document.getElementById('addDialog').style.display = 'flex';
}

function closeAddDialog() {
    document.getElementById('addDialog').style.display = 'none';
    document.getElementById('manualInput').style.display = 'none';
    document.getElementById('bufferInput').style.display = 'none';
}

function showManualInput() {
    document.getElementById('manualInput').style.display = 'block';
    document.getElementById('bufferInput').style.display = 'none';
}

function importFromBuffer() {
    document.getElementById('manualInput').style.display = 'none';
    document.getElementById('bufferInput').style.display = 'block';
}

function addConfig() {
    const name = document.getElementById('configName').value.trim();
    const link = document.getElementById('configLink').value.trim();
    const serverIP = document.getElementById('serverIP').value.trim();
    const localPort = document.getElementById('localPort').value.trim();
    const dtlsPort = document.getElementById('dtlsPort').value.trim();
    const wgPort = document.getElementById('wgPort').value.trim();
    const hash = document.getElementById('configHash').value.trim();
    const password = document.getElementById('configPassword').value.trim();

    if (!serverIP || !localPort || !hash) {
        alert('Заполните обязательные поля: IP, порт, хеш');
        return;
    }

    const config = {
        name: name || serverIP,
        serverIP: serverIP,
        localPort: localPort,
        dtlsPort: dtlsPort || '5636',
        wgPort: wgPort || '9000',
        hash: hash,
        password: password || '',
        link: link || `wdtt://${serverIP}:${dtlsPort || '5636'}:${localPort}:${wgPort || '9000'}:${password || ''}:${hash}`
    };

    configs.push(config);
    localStorage.setItem('wdtt_configs', JSON.stringify(configs));
    loadConfigs();
    closeAddDialog();
}

function parseBuffer() {
    const text = document.getElementById('bufferText').value.trim();
    if (!text) {
        alert('Буфер пуст');
        return;
    }

    const parts = text.split(':');
    if (parts.length >= 6) {
        const config = {
            name: 'Импортированный',
            serverIP: parts[1],
            localPort: parts[3],
            dtlsPort: parts[2],
            wgPort: parts[4],
            password: parts[5],
            hash: parts.slice(6).join(':'),
            link: text
        };
        configs.push(config);
        localStorage.setItem('wdtt_configs', JSON.stringify(configs));
        loadConfigs();
        closeAddDialog();
    } else {
        alert('Неверный формат ссылки');
    }
}

function handleConnect() {
    if (!selectedConfig) {
        alert('Выберите конфигурацию');
        return;
    }

    if (isConnected) {
        disconnect();
        return;
    }

    const btn = document.getElementById('connectBtn');
    btn.querySelector('span').textContent = 'Подключение...';
    btn.style.pointerEvents = 'none';

    const params = new URLSearchParams({
        peer: selectedConfig.serverIP,
        vk: selectedConfig.hash,
        n: '50',
        listen: ':' + selectedConfig.localPort
    });

    fetch('/api/start?' + params)
        .then(res => res.json())
        .then(data => {
            if (data.status === 'started') {
                return fetch('/api/start-tunnel?config_file=' + encodeURIComponent(data.config || 'config.toml'));
            }
            throw new Error('Start failed');
        })
        .then(res => res.json())
        .then(data => {
            if (data.status === 'tunnel_established') {
                isConnected = true;
                btn.querySelector('span').textContent = 'Отключить';
                btn.querySelector('img').src = '/static/images/disconnect.svg';
                btn.style.pointerEvents = 'auto';
            }
        })
        .catch(err => {
            alert('Ошибка подключения: ' + err.message);
            btn.querySelector('span').textContent = 'Подключить';
            btn.style.pointerEvents = 'auto';
        });
}

function disconnect() {
    const btn = document.getElementById('connectBtn');
    btn.querySelector('span').textContent = 'Отключение...';
    btn.style.pointerEvents = 'none';

    fetch('/api/disconnect')
        .then(res => res.json())
        .then(data => {
            if (data.status === 'disconnected') {
                isConnected = false;
                btn.querySelector('span').textContent = 'Подключить';
                btn.querySelector('img').src = '/static/images/connect.svg';
                btn.style.pointerEvents = 'auto';
            }
        })
        .catch(err => {
            alert('Ошибка отключения: ' + err.message);
            btn.style.pointerEvents = 'auto';
        });
}

function getReport() {
    fetch('/api/logs')
        .then(res => res.text())
        .then(data => {
            const blob = new Blob([data], {type: 'text/plain'});
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = 'wdtt_report_' + new Date().toISOString().slice(0,19) + '.log';
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
        })
        .catch(err => {
            alert('Ошибка получения отчета: ' + err.message);
        });
}

loadTheme();
