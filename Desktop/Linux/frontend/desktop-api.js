// Desktop API для LaLune

if (typeof window._lalune_loaded === 'undefined') {
    window._lalune_loaded = true;
    
    let currentConfigs = [];
    let selectedConfigId = null;
    let isConnected = false;
    let currentTab = 'connection';
    let logPollTimer = null;
    let statusPollTimer = null;
    let isCheckingUpdate = false;
    let isUpdating = false;

    let currentSettings = {
        peer: '',
        vkHashes: '',
        password: '',
        workersPerHash: 9
    };

    function getApi() {
        if (window.go && window.go.main && window.go.main.App) {
            return window.go.main.App;
        }
        return null;
    }

    document.addEventListener('DOMContentLoaded', function() {
        console.log('LaLune Desktop UI загружен');
        createStars();
        loadConfigs();
        startPolling();
        switchTab('connection');
    });

    function startPolling() {
        statusPollTimer = setInterval(function() {
            const api = getApi();
            if (!api) return;
            api.GetStatusJson().then(function(result) {
                try {
                    const status = JSON.parse(result);
                    if (status.connected !== isConnected) {
                        setConnected(status.connected);
                    }
                } catch(e) {}
            }).catch(function() {});
        }, 2000);

        logPollTimer = setInterval(function() {
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
            star.style.animationDelay = Math.random() * 3 + 's';
            container.appendChild(star);
        }
    }

    function loadConfigs() {
        const api = getApi();
        if (!api) {
            setTimeout(loadConfigs, 1000);
            return;
        }
        
        api.GetConfigsJson().then(function(result) {
            try {
                currentConfigs = JSON.parse(result);
                renderConfigs();
            } catch(e) {
                currentConfigs = [];
                renderConfigs();
            }
        }).catch(function() {
            currentConfigs = [];
            renderConfigs();
        });
    }

    function renderConfigs() {
        const dropdown = document.getElementById('configDropdown');
        if (!dropdown) return;
        
        dropdown.innerHTML = '';
        
        if (currentConfigs.length === 0) {
            dropdown.innerHTML = '<div class="config-item" style="justify-content:center;color:rgba(255,255,255,0.5);">Нет конфигов. Нажмите + чтобы добавить</div>';
            return;
        }
        
        currentConfigs.forEach(function(config) {
            const item = document.createElement('div');
            item.className = 'config-item';
            if (selectedConfigId === config.id) item.classList.add('selected');
            
            const badge = document.createElement('span');
            badge.className = 'protocol-badge';
            badge.textContent = config.protocol || 'CSQTT';
            item.appendChild(badge);
            
            const nameSpan = document.createElement('span');
            nameSpan.className = 'config-name';
            nameSpan.textContent = config.name || config.peer || 'Config';
            item.appendChild(nameSpan);
            
            const deleteBtn = document.createElement('button');
            deleteBtn.className = 'delete-btn';
            deleteBtn.innerHTML = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.4)" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>';
            deleteBtn.onclick = function(e) {
                e.stopPropagation();
                deleteConfig(config.id);
            };
            item.appendChild(deleteBtn);
            
            item.onclick = function() {
                selectConfig(config.id);
            };
            
            dropdown.appendChild(item);
        });
        
        updateSelectedConfigName();
    }

    function updateSelectedConfigName() {
        const nameSpan = document.getElementById('selectedConfigName');
        if (!nameSpan) return;
        if (selectedConfigId === null) {
            nameSpan.textContent = 'Выберите конфиг';
            return;
        }
        const config = currentConfigs.find(c => c.id === selectedConfigId);
        nameSpan.textContent = config ? (config.name || config.peer || 'Config') : 'Выберите конфиг';
    }

    function toggleConfigDropdown() {
        const dropdown = document.getElementById('configDropdown');
        const header = document.querySelector('.config-selector-header');
        if (!dropdown || !header) return;
        dropdown.classList.toggle('open');
        header.classList.toggle('open');
    }

    function selectConfig(id) {
        selectedConfigId = id;
        
        const config = currentConfigs.find(c => c.id === id);
        if (!config) return;

        currentSettings.peer = config.peer || '';
        currentSettings.vkHashes = config.hashes || '';
        currentSettings.password = config.password || '';

        updateSelectedConfigName();
        const dropdown = document.getElementById('configDropdown');
        const header = document.querySelector('.config-selector-header');
        if (dropdown) dropdown.classList.remove('open');
        if (header) header.classList.remove('open');
        
        document.querySelectorAll('.config-item').forEach(function(item) {
            item.classList.remove('selected');
        });
        
        const statusText = document.getElementById('statusText');
        if (statusText) statusText.textContent = 'Готов к подключению';

        if (currentTab === 'settings') {
            renderSettingsTab();
        }
    }

    function deleteConfig(id) {
        if (!confirm('Удалить этот конфиг?')) return;
        const api = getApi();
        if (!api) return;
        
        api.DeleteConfig(id).then(function(result) {
            if (result) {
                showToast('Конфиг удален');
                if (selectedConfigId === id) {
                    selectedConfigId = null;
                    currentSettings = {
                        peer: '',
                        vkHashes: '',
                        password: '',
                        workersPerHash: 9
                    };
                }
                loadConfigs();
            } else {
                showToast('Ошибка удаления');
            }
        }).catch(function() {
            showToast('Ошибка удаления');
        });
    }

    function saveConfig() {
        const input = document.getElementById('configInput');
        if (!input || !input.value.trim()) {
            showToast('Введите ссылку');
            return;
        }
        const link = input.value.trim();
        const api = getApi();
        if (!api) return;
        
        api.SaveConfig(link).then(function(result) {
            if (result) {
                showToast('Конфиг сохранен');
                closeAddModal();
                loadConfigs();
            } else {
                showToast('Ошибка сохранения');
            }
        }).catch(function() {
            showToast('Ошибка сохранения');
        });
    }

    function toggleConnect() {
        if (isConnected) {
            disconnect();
        } else {
            connectWithUpdateCheck();
        }
    }

    function connectWithUpdateCheck() {
        if (isCheckingUpdate || isUpdating) return;
        
        const api = getApi();
        if (!api) return;
        
        isCheckingUpdate = true;
        showToast('Проверка обновлений...');
        
        api.CheckUpdate().then(function(result) {
            isCheckingUpdate = false;
            try {
                const data = JSON.parse(result);
                if (data.update) {
                    showUpdateBanner(data.version);
                    showToast('Доступна новая версия!');
                } else {
                    connect();
                }
            } catch(e) {
                connect();
            }
        }).catch(function() {
            isCheckingUpdate = false;
            connect();
        });
    }

    function connect() {
        const api = getApi();
        if (!api) return;
        
        const settings = {
            peer: currentSettings.peer,
            vkHashes: currentSettings.vkHashes,
            workersPerHash: currentSettings.workersPerHash,
            obfs: document.getElementById('settingObfs')?.value || 'video',
            fingerprint: document.getElementById('settingFingerprint')?.value || 'firefox',
            clientIds: document.getElementById('settingClientIds')?.value || '8202606,6287487',
            vkAuthMode: 'vkcalls',
            captchaMode: 'auto',
            deviceId: '',
            autoConnect: false,
            password: currentSettings.password
        };

        if (!settings.peer || !settings.password) {
            showToast('Выберите конфиг или заполните настройки');
            return;
        }

        api.SaveSettings(JSON.stringify(settings)).then(function(saved) {
            if (saved && selectedConfigId !== null) {
                api.Connect(selectedConfigId).then(function(result) {
                    if (result) {
                        showToast('Подключение...');
                    } else {
                        showToast('Ошибка подключения');
                    }
                }).catch(function() {
                    showToast('Ошибка подключения');
                });
            } else if (!saved) {
                showToast('Ошибка сохранения настроек');
            } else {
                showToast('Выберите конфиг');
            }
        }).catch(function() {
            showToast('Ошибка сохранения настроек');
        });
    }

    function disconnect() {
        const api = getApi();
        if (!api) return;
        
        api.Disconnect().then(function(result) {
            if (result) {
                showToast('Отключено');
            }
        }).catch(function() {});
    }

    function setConnected(connected) {
        isConnected = connected;
        const statusText = document.getElementById('statusText');
        const moonBtn = document.getElementById('moonBtn');
        const moonStars = document.getElementById('moonStars');
        if (statusText) {
            statusText.textContent = connected ? 'Подключено' : 'Отключено';
        }
        if (moonBtn) {
            moonBtn.disabled = false;
            moonBtn.style.opacity = '1';
        }
        if (moonStars) {
            if (connected) {
                moonStars.classList.add('active');
            } else {
                moonStars.classList.remove('active');
            }
        }
    }

    function loadLogs() {
        const api = getApi();
        if (!api) return;
        
        api.GetLogsJson().then(function(result) {
            try {
                const logs = JSON.parse(result);
                renderLogs(logs);
            } catch(e) {}
        }).catch(function() {});
    }

    function renderLogs(logs) {
        const content = document.getElementById('logsContent');
        if (!content) return;
        if (!logs || logs.length === 0) {
            content.textContent = 'Логи пусты';
            return;
        }
        content.textContent = logs.join('\n');
        content.scrollTop = content.scrollHeight;
    }

    function clearLogs() {
        const api = getApi();
        if (!api) return;
        
        api.ClearLogs().then(function(result) {
            if (result) {
                const content = document.getElementById('logsContent');
                if (content) content.textContent = 'Логи очищены';
                showToast('Логи очищены');
            }
        }).catch(function() {});
    }

    function switchTab(tab) {
        currentTab = tab;
        document.querySelectorAll('.nav-btn').forEach(function(btn) {
            btn.classList.remove('active');
            if (btn.dataset.tab === tab) {
                btn.classList.add('active');
            }
        });
        
        const container = document.getElementById('content');
        if (!container) return;
        
        container.innerHTML = '';
        container.style.justifyContent = 'center';
        container.style.overflowY = 'auto';
        
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
        container.style.justifyContent = 'center';
        container.style.overflowY = 'hidden';
        
        const moonContainer = document.createElement('div');
        moonContainer.className = 'moon-container';
        moonContainer.id = 'moonContainer';
        moonContainer.innerHTML = `
            <button class="moon-btn" id="moonBtn" onclick="toggleConnect()">
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="100" height="100">
                    <circle cx="50" cy="50" r="48" fill="#1a1a3e" stroke="#4a6cf7" stroke-width="2"/>
                    <path d="M 60 18 A 28 28 0 1 0 82 58 A 34 34 0 1 1 60 18 Z" fill="#f7e84e" stroke="#d4c42a" stroke-width="1.5"/>
                    <circle cx="28" cy="30" r="2" fill="#4a6cf7" opacity="0.35"/>
                    <circle cx="74" cy="26" r="1.5" fill="#4a6cf7" opacity="0.25"/>
                    <circle cx="22" cy="70" r="1.8" fill="#4a6cf7" opacity="0.3"/>
                    <circle cx="78" cy="68" r="1.2" fill="#4a6cf7" opacity="0.2"/>
                    <circle cx="34" cy="76" r="1.5" fill="#4a6cf7" opacity="0.25"/>
                </svg>
            </button>
            <div class="moon-stars" id="moonStars">
                <div class="moon-star" style="left:15%;top:10%;width:6px;height:6px;"></div>
                <div class="moon-star" style="left:75%;top:25%;width:4px;height:4px;animation-delay:0.3s;"></div>
                <div class="moon-star" style="left:20%;top:60%;width:5px;height:5px;animation-delay:0.5s;"></div>
                <div class="moon-star" style="left:85%;top:65%;width:3px;height:3px;animation-delay:0.2s;"></div>
                <div class="moon-star" style="left:50%;top:80%;width:7px;height:7px;animation-delay:0.6s;"></div>
                <div class="moon-star" style="left:65%;top:5%;width:5px;height:5px;animation-delay:0.4s;"></div>
            </div>
        `;
        container.appendChild(moonContainer);
        
        const statusText = document.createElement('div');
        statusText.className = 'status-text';
        statusText.id = 'statusText';
        statusText.textContent = isConnected ? 'Подключено' : 'Отключено';
        container.appendChild(statusText);
        
        const configSelector = document.createElement('div');
        configSelector.className = 'config-selector';
        configSelector.innerHTML = `
            <div class="config-selector-header" onclick="toggleConfigDropdown()">
                <span id="selectedConfigName">Выберите конфиг</span>
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2">
                    <polyline points="6 9 12 15 18 9"/>
                </svg>
            </div>
            <div class="config-dropdown" id="configDropdown"></div>
        `;
        container.appendChild(configSelector);
        
        renderConfigs();
        setConnected(isConnected);
    }

    function renderLogsTab(container) {
        container.style.justifyContent = 'flex-start';
        container.style.overflowY = 'hidden';
        
        const logsContainer = document.createElement('div');
        logsContainer.id = 'logsContainer';
        logsContainer.className = 'logs-container';
        logsContainer.style.display = 'block';
        logsContainer.style.width = '100%';
        logsContainer.style.maxWidth = '600px';
        logsContainer.innerHTML = `
            <div class="logs-header">
                <h3>Логи</h3>
                <button class="btn-clear" onclick="clearLogs()">
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <polyline points="3 6 5 6 21 6"/>
                        <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>
                    </svg>
                </button>
            </div>
            <div id="logsContent">Загрузка логов...</div>
        `;
        container.appendChild(logsContainer);
        
        loadLogs();
    }

    function renderSettingsTab(container) {
        container.style.justifyContent = 'flex-start';
        container.style.overflowY = 'auto';
        
        const settingsBlock = document.createElement('div');
        settingsBlock.id = 'settingsBlock';
        settingsBlock.style.width = '100%';
        settingsBlock.style.maxWidth = '500px';
        settingsBlock.innerHTML = `
            <div class="settings-scroll">
                <div class="settings-group">
                    <div class="group-title open" onclick="toggleSettingsGroup(this)">
                        <span>Основные настройки</span>
                        <span class="arrow">▼</span>
                    </div>
                    <div class="group-body open">
                        <div class="settings-row">
                            <label>Peer</label>
                            <input type="text" id="settingPeer" placeholder="host:port" value="${currentSettings.peer || ''}">
                        </div>
                        <div class="settings-row">
                            <label>VK Hashes</label>
                            <input type="text" id="settingVkHashes" placeholder="hash1,hash2,hash3" value="${currentSettings.vkHashes || ''}">
                        </div>
                        <div class="settings-row">
                            <label>Password</label>
                            <input type="password" id="settingPassword" placeholder="password" value="${currentSettings.password || ''}">
                        </div>
                        <div class="settings-row">
                            <label>Workers on hash</label>
                            <input type="number" id="settingWorkers" value="${currentSettings.workersPerHash || 9}" min="9" max="27">
                        </div>
                    </div>
                </div>
                <div class="settings-group">
                    <div class="group-title" onclick="toggleSettingsGroup(this)">
                        <span>Продвинутые настройки</span>
                        <span class="arrow">▼</span>
                    </div>
                    <div class="group-body">
                        <div class="settings-row">
                            <label>Obfs</label>
                            <select id="settingObfs">
                                <option value="video">video</option>
                                <option value="audio">audio</option>
                                <option value="text">text</option>
                            </select>
                        </div>
                        <div class="settings-row">
                            <label>Fingerprint</label>
                            <select id="settingFingerprint">
                                <option value="firefox">firefox</option>
                                <option value="chrome">chrome</option>
                                <option value="edge">edge</option>
                            </select>
                        </div>
                        <div class="settings-row">
                            <label>Client IDs</label>
                            <input type="text" id="settingClientIds" value="8202606,6287487">
                        </div>
                        <div class="settings-row">
                            <label>Turn Host</label>
                            <input type="text" id="settingTurnHost" placeholder="turn.example.com">
                        </div>
                        <div class="settings-row">
                            <label>Turn Port</label>
                            <input type="text" id="settingTurnPort" placeholder="3478">
                        </div>
                        <div class="settings-row">
                            <label>Auto Connect</label>
                            <div class="toggle-label">
                                <input type="checkbox" id="settingAutoConnect">
                            </div>
                        </div>
                    </div>
                </div>
                <button class="btn-primary" style="width:100%;margin-top:10px;" onclick="saveSettings()">Сохранить настройки</button>
            </div>
        `;
        container.appendChild(settingsBlock);
        
        const api = getApi();
        if (!api) return;
        
        api.GetSettingsJson().then(function(result) {
            try {
                const settings = JSON.parse(result);
                document.getElementById('settingObfs').value = settings.obfs || 'video';
                document.getElementById('settingFingerprint').value = settings.fingerprint || 'firefox';
                document.getElementById('settingClientIds').value = settings.clientIds || '8202606,6287487';
                document.getElementById('settingTurnHost').value = settings.turnHost || '';
                document.getElementById('settingTurnPort').value = settings.turnPort || '';
                document.getElementById('settingAutoConnect').checked = settings.autoConnect || false;
                if (settings.workersPerHash) {
                    currentSettings.workersPerHash = settings.workersPerHash;
                    document.getElementById('settingWorkers').value = settings.workersPerHash;
                }
            } catch(e) {}
        }).catch(function() {});
    }

    function saveSettings() {
        currentSettings.peer = document.getElementById('settingPeer')?.value || '';
        currentSettings.vkHashes = document.getElementById('settingVkHashes')?.value || '';
        currentSettings.password = document.getElementById('settingPassword')?.value || '';
        currentSettings.workersPerHash = parseInt(document.getElementById('settingWorkers')?.value) || 9;

        const settings = {
            peer: currentSettings.peer,
            vkHashes: currentSettings.vkHashes,
            turnHost: document.getElementById('settingTurnHost')?.value || '',
            turnPort: document.getElementById('settingTurnPort')?.value || '',
            workersPerHash: currentSettings.workersPerHash,
            obfs: document.getElementById('settingObfs')?.value || 'video',
            fingerprint: document.getElementById('settingFingerprint')?.value || 'firefox',
            clientIds: document.getElementById('settingClientIds')?.value || '8202606,6287487',
            vkAuthMode: 'vkcalls',
            captchaMode: 'auto',
            deviceId: '',
            autoConnect: document.getElementById('settingAutoConnect')?.checked || false
        };

        const api = getApi();
        if (!api) return;
        
        api.SaveSettings(JSON.stringify(settings)).then(function(result) {
            if (result) {
                showToast('Настройки сохранены');
            } else {
                showToast('Ошибка сохранения');
            }
        }).catch(function() {
            showToast('Ошибка сохранения');
        });
    }

    function renderInfoTab(container) {
        container.style.justifyContent = 'flex-start';
        container.style.overflowY = 'auto';
        container.style.paddingTop = '20px';
        
        const infoBlock = document.createElement('div');
        infoBlock.id = 'infoBlock';
        infoBlock.style.textAlign = 'center';
        infoBlock.style.width = '100%';
        infoBlock.style.maxWidth = '450px';
        infoBlock.innerHTML = `
            <div class="info-title">🌙 LaLune</div>
            <div class="info-sub">Desktop Client v0.5.0</div>
            
            <div class="info-block">
                <div class="label">Версия ядра</div>
                <div class="value">2.0.0</div>
            </div>
            
            <div class="info-block">
                <div class="label">Авторы</div>
                <div class="value" style="line-height:1.8;">
                    <div>CSQTT — <span style="color:#4a6cf7;">amurcanov</span></div>
                    <div>LaLune — <span style="color:#4a6cf7;">@Endlad7373</span></div>
                </div>
            </div>
            
            <div class="info-block" style="text-align:left;">
                <div class="label" style="margin-bottom:8px;">Поддержать LaLune</div>
                <div class="value" style="line-height:1.6;font-size:14px;">
                    <div>💳 Сбер: <span style="color:#4a6cf7;">2202208453630882</span></div>
                    <div>🎨 NFT: <span style="color:#4a6cf7;">в Telegram @Endlad7373</span></div>
                </div>
            </div>
            
            <div class="info-block" style="text-align:left;">
                <div class="label" style="margin-bottom:8px;">Поддержать CSQTT</div>
                <div class="value" style="line-height:1.8;font-size:14px;">
                    <div>💳 ЮMoney: <a href="https://yoomoney.ru/to/4100119505530465/100" target="_blank" style="color:#4a6cf7;">yoomoney.ru/to/4100119505530465/100</a></div>
                    <div>💎 GRAM (TON):<br><span style="color:#4a6cf7;word-break:break-all;">UQCsHSj_Bev5AG3vCz-84TQC7BSwjNdNdoJp9M2gWUEmbyD7</span></div>
                    <div>💎 USDT (TON):<br><span style="color:#4a6cf7;word-break:break-all;">UQCsHSj_Bev5AG3vCz-84TQC7BSwjNdNdoJp9M2gWUEmbyD7</span></div>
                    <div>💎 USDT (TRC20):<br><span style="color:#4a6cf7;word-break:break-all;">TD1oiQiHmjqsRDPxfUjUbSWxEmcr4k7Lob</span></div>
                </div>
            </div>
        `;
        container.appendChild(infoBlock);
    }

    function toggleSettingsGroup(el) {
        el.classList.toggle('open');
        const body = el.parentElement.querySelector('.group-body');
        if (body) {
            body.classList.toggle('open');
        }
    }

    function showAddModal() {
        document.getElementById('addModal').classList.add('open');
        document.getElementById('configInput').value = '';
    }

    function closeAddModal() {
        document.getElementById('addModal').classList.remove('open');
    }

    function setImportMethod(method) {
        document.querySelectorAll('.import-btn').forEach(function(btn) {
            btn.classList.remove('active');
        });
        event.target.classList.add('active');
        if (method === 'clipboard') {
            if (navigator.clipboard) {
                navigator.clipboard.readText().then(function(text) {
                    document.getElementById('configInput').value = text;
                    showToast('Вставлено из буфера обмена');
                }).catch(function() {
                    showToast('Нет доступа к буферу обмена');
                });
            } else {
                showToast('Буфер обмена не поддерживается');
            }
        }
    }

    function showToast(message) {
        const toast = document.getElementById('toast');
        if (!toast) return;
        toast.textContent = message;
        toast.classList.add('show');
        clearTimeout(toast._timeout);
        toast._timeout = setTimeout(function() {
            toast.classList.remove('show');
        }, 3000);
    }

    function showUpdateBanner(version) {
        const banner = document.getElementById('updateBanner');
        if (!banner) return;
        banner.innerHTML = '<span>Доступна новая версия: ' + version + '</span><button onclick="updateCoreFromBanner()">Обновить</button>';
        banner.classList.add('show');
    }

    function updateCoreFromBanner() {
        if (isUpdating) return;
        isUpdating = true;
        
        const api = getApi();
        if (!api) {
            isUpdating = false;
            return;
        }
        
        showToast('Обновление...');
        
        api.UpdateCoreAndWait().then(function(result) {
            isUpdating = false;
            if (result) {
                document.getElementById('updateBanner').classList.remove('show');
                showToast('Обновление успешно! Можно подключаться');
            } else {
                showToast('Ошибка обновления');
            }
        }).catch(function() {
            isUpdating = false;
            showToast('Ошибка обновления');
        });
    }

    function updateCore() {
        if (isUpdating) return;
        isUpdating = true;
        
        const api = getApi();
        if (!api) {
            isUpdating = false;
            return;
        }
        
        showToast('Обновление...');
        
        api.UpdateCoreAndWait().then(function(result) {
            isUpdating = false;
            if (result) {
                showToast('Обновление успешно!');
            } else {
                showToast('Ошибка обновления');
            }
        }).catch(function() {
            isUpdating = false;
            showToast('Ошибка обновления');
        });
    }

    // Экспорт
    window.loadConfigs = loadConfigs;
    window.renderConfigs = renderConfigs;
    window.selectConfig = selectConfig;
    window.deleteConfig = deleteConfig;
    window.saveConfig = saveConfig;
    window.toggleConnect = toggleConnect;
    window.connect = connect;
    window.connectWithUpdateCheck = connectWithUpdateCheck;
    window.disconnect = disconnect;
    window.setConnected = setConnected;
    window.loadLogs = loadLogs;
    window.clearLogs = clearLogs;
    window.switchTab = switchTab;
    window.saveSettings = saveSettings;
    window.showAddModal = showAddModal;
    window.closeAddModal = closeAddModal;
    window.setImportMethod = setImportMethod;
    window.showToast = showToast;
    window.showUpdateBanner = showUpdateBanner;
    window.updateCore = updateCore;
    window.updateCoreFromBanner = updateCoreFromBanner;
    window.toggleConfigDropdown = toggleConfigDropdown;
    window.toggleSettingsGroup = toggleSettingsGroup;

    console.log('LaLune Desktop API загружен');
}
