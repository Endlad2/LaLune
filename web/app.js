let currentConfig = null;
let isConnected = false;
let isConnecting = false;

document.addEventListener('DOMContentLoaded', function() {
    const tabs = document.querySelectorAll('.nav-btn');
    const configsContainer = document.getElementById('configsContainer');
    const addConfigBtn = document.getElementById('addConfigBtn');
    const connectBtn = document.getElementById('connectBtn');
    const disconnectBtn = document.getElementById('disconnectBtn');
    const themeToggle = document.getElementById('themeToggle');
    const reportBtn = document.getElementById('reportBtn');
    const modal = document.getElementById('addConfigModal');
    const modalClose = document.getElementById('modalCloseBtn');
    const addConfirm = document.getElementById('addConfirmBtn');
    
    loadConfigs();
    
    tabs.forEach(tab => {
        tab.addEventListener('click', function() {
            tabs.forEach(t => t.classList.remove('active'));
            this.classList.add('active');
            switchTab(this.dataset.tab);
        });
    });
    
    addConfigBtn.addEventListener('click', function() {
        modal.classList.add('active');
    });
    
    modalClose.addEventListener('click', function() {
        modal.classList.remove('active');
        document.getElementById('configForm').style.display = 'none';
    });
    
    document.querySelectorAll('.modal-option').forEach(option => {
        option.addEventListener('click', function() {
            const form = document.getElementById('configForm');
            form.style.display = 'block';
            if (this.dataset.type === 'import') {
                navigator.clipboard.readText().then(text => {
                    document.getElementById('configLink').value = text;
                    parseConfigLink(text);
                });
            }
        });
    });
    
    addConfirm.addEventListener('click', function() {
        const config = {
            name: document.getElementById('configName').value || 'Сервер',
            ip: document.getElementById('configIP').value,
            local_port: parseInt(document.getElementById('configLocalPort').value) || 56006,
            dtls_port: parseInt(document.getElementById('configDTLSPort').value) || 5636,
            wg_port: parseInt(document.getElementById('configWGPort').value) || 9000,
            password: document.getElementById('configPassword').value,
            hashes: document.getElementById('configHashes').value.split(',').map(h => h.trim()).filter(h => h),
            link: document.getElementById('configLink').value
        };
        
        if (!config.ip || !config.password || config.hashes.length === 0) {
            alert('Заполните все обязательные поля');
            return;
        }
        
        saveConfig(config);
        modal.classList.remove('active');
        document.getElementById('configForm').style.display = 'none';
        loadConfigs();
    });
    
    connectBtn.addEventListener('click', function() {
        if (!currentConfig) {
            alert('Выберите конфиг');
            return;
        }
        connectToServer();
    });
    
    disconnectBtn.addEventListener('click', function() {
        disconnectFromServer();
    });
    
    themeToggle.addEventListener('click', function() {
        document.body.classList.toggle('light-theme');
        localStorage.setItem('theme', document.body.classList.contains('light-theme') ? 'light' : 'dark');
    });
    
    if (localStorage.getItem('theme') === 'light') {
        document.body.classList.add('light-theme');
    }
    
    reportBtn.addEventListener('click', function() {
        fetch('/api/logs')
            .then(response => response.text())
            .then(data => {
                const blob = new Blob([data], {type: 'text/plain'});
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = 'la-lune-logs-' + new Date().toISOString().slice(0,10) + '.txt';
                a.click();
                URL.revokeObjectURL(url);
            })
            .catch(err => alert('Не удалось получить логи: ' + err));
    });
    
    function switchTab(tab) {
        document.querySelectorAll('.tab-content').forEach(el => el.classList.remove('active'));
        let content;
        switch(tab) {
            case 'connection':
                content = document.getElementById('mainContent');
                break;
            case 'support':
                content = createSupportTab();
                break;
            case 'logs':
                content = createLogsTab();
                break;
            case 'authors':
                content = createAuthorsTab();
                break;
        }
        
        if (content) {
            document.querySelector('.main-content').innerHTML = '';
            document.querySelector('.main-content').appendChild(content);
        }
    }
    
    function createSupportTab() {
        const div = document.createElement('div');
        div.className = 'tab-content active support-content';
        div.innerHTML = '<a href="https://yoomoney.ru/to/4100119505530465/100" target="_blank" class="support-btn">Поддержать amurcanov</a><div class="support-info"><p><strong>Поддержать меня</strong></p><p>Банковская карта: 2202208453630882</p><p>USDT (TRC20): TKzkLotY8rpR81vDiUaB891aZcmZjbTveP</p></div>';
        return div;
    }
    
    function createLogsTab() {
        const div = document.createElement('div');
        div.className = 'tab-content active logs-content';
        div.id = 'logsContent';
        loadLogs(div);
        setInterval(function() { loadLogs(div); }, 5000);
        return div;
    }
    
    function loadLogs(container) {
        fetch('/api/logs')
            .then(response => response.text())
            .then(data => {
                container.textContent = data || 'Логи отсутствуют';
            })
            .catch(function() {
                container.textContent = 'Не удалось загрузить логи';
            });
    }
    
    function createAuthorsTab() {
        const div = document.createElement('div');
        div.className = 'tab-content active authors-content';
        div.innerHTML = '<div class="author-card"><h3>Amurcanov</h3><p>Разработчик оригинального WDTT</p><a href="https://github.com/amurcanov" target="_blank" class="author-link">GitHub</a></div><div class="author-card"><h3>Endlad</h3><p>Разработчик La Lune и WDTT-rslib</p><a href="https://github.com/Endlad2" target="_blank" class="author-link">GitHub</a><p>Telegram: <a href="https://t.me/Endlad7373" target="_blank" class="author-link">@Endlad7373</a></p></div><div class="author-footer">Для помощи пишите сюда: <a href="https://t.me/Endlad7373" target="_blank" class="author-link">@Endlad7373</a></div>';
        return div;
    }
    
    function loadConfigs() {
        fetch('/api/configs')
            .then(response => response.json())
            .then(configs => {
                const container = document.getElementById('configsContainer');
                container.innerHTML = '';
                configs.forEach(function(config, index) {
                    const el = document.createElement('div');
                    el.className = 'config-item';
                    el.textContent = config.name || 'Сервер';
                    el.dataset.index = index;
                    el.addEventListener('click', function() {
                        document.querySelectorAll('.config-item').forEach(function(c) { c.classList.remove('active'); });
                        this.classList.add('active');
                        currentConfig = configs[index];
                    });
                    container.appendChild(el);
                });
            })
            .catch(function(err) { console.error('Не удалось загрузить конфиги:', err); });
    }
    
    function saveConfig(config) {
        fetch('/api/configs', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify(config)
        });
    }
    
    function parseConfigLink(link) {
        try {
            const url = new URL(link);
            const parts = url.host.split(':');
            document.getElementById('configIP').value = parts[0] || '';
            document.getElementById('configDTLSPort').value = parts[1] || '';
            document.getElementById('configLocalPort').value = parts[2] || '';
            document.getElementById('configWGPort').value = parts[3] || '';
            document.getElementById('configPassword').value = parts[4] || '';
            const hashes = parts.slice(5).filter(function(h) { return h; });
            document.getElementById('configHashes').value = hashes.join(',');
        } catch(e) {}
    }
    
    function connectToServer() {
        if (isConnecting || isConnected) return;
        
        isConnecting = true;
        const connectCard = document.getElementById('connectCard');
        const connectBtn = document.getElementById('connectBtn');
        connectBtn.textContent = 'Подключение...';
        connectBtn.disabled = true;
        
        const payload = {
            peer: currentConfig.ip + ':' + currentConfig.dtls_port,
            vk: currentConfig.hashes.join(','),
            n: 109,
            listen: '0.0.0.0:' + currentConfig.local_port
        };
        
        fetch('/api/start', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify(payload)
        })
        .then(function(response) { return response.json(); })
        .then(function(data) {
            if (data.status === 'started') {
                return fetch('/api/start-tunnel', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({config_file: 'config.toml'})
                });
            }
            throw new Error('Не удалось запустить WDTT');
        })
        .then(function(response) { return response.json(); })
        .then(function(data) {
            if (data.status === 'tunnel_started') {
                isConnected = true;
                isConnecting = false;
                document.getElementById('connectCard').style.display = 'none';
                document.getElementById('disconnectArea').style.display = 'flex';
            }
        })
        .catch(function(err) {
            alert('Ошибка подключения: ' + err.message);
            isConnecting = false;
            connectBtn.textContent = 'Подключить';
            connectBtn.disabled = false;
        });
    }
    
    function disconnectFromServer() {
        if (!isConnected) return;
        
        fetch('/api/disconnect', {
            method: 'POST'
        })
        .then(function(response) { return response.json(); })
        .then(function(data) {
            if (data.status === 'disconnected') {
                isConnected = false;
                document.getElementById('connectCard').style.display = 'flex';
                document.getElementById('disconnectArea').style.display = 'none';
                const connectBtn = document.getElementById('connectBtn');
                connectBtn.textContent = 'Подключить';
                connectBtn.disabled = false;
            }
        })
        .catch(function(err) {
            alert('Ошибка отключения: ' + err.message);
        });
    }
});