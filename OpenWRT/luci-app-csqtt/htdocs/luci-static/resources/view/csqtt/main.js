/*
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 *
 * luci-app-csqtt — UI для подключения к CSQTT на OpenWRT.
 *
 * Вкладки:
 *   1) Подключение — ссылка, токен, хеши, воркеры, кнопка «Подключить»
 *   2) Логи        — вывод /etc/csqtt/csqtt.log
 *   3) Поддержать  — реквизиты авторов
 */

'use strict';
'require view';
'require form';
'require rpc';
'require ui';
'require poll';

const callConnect    = rpc.declare({ object: 'luci.csqtt', method: 'connect',    params: ['link','hashes','workers','token'] });
const callDisconnect = rpc.declare({ object: 'luci.csqtt', method: 'disconnect' });
const callStatus     = rpc.declare({ object: 'luci.csqtt', method: 'status'     });
const callLogs       = rpc.declare({ object: 'luci.csqtt', method: 'logs',       params: ['n'] });

const LS_LINK    = 'csqtt.link';
const LS_TOKEN   = 'csqtt.token';
const LS_HASHES  = 'csqtt.hashes';
const LS_WORKERS = 'csqtt.workers';

return view.extend({
    load: function () {
        return callStatus().then(function (res) {
            let raw = { running: false, pid: 0, connected: false, core_running: false };
            try { raw = JSON.parse(res.raw || '{}'); } catch (e) {}
            return {
                status:  raw,
                link:    localStorage.getItem(LS_LINK)    || '',
                token:   localStorage.getItem(LS_TOKEN)   || '',
                hashes:  localStorage.getItem(LS_HASHES)  || '3',
                workers: localStorage.getItem(LS_WORKERS) || '27'
            };
        });
    },

    render: function (data) {
        const self = this;
        const m = new form.Map('csqtt', _('CSQTT'),
            _('Подключение к VPN-серверу CSQTT (протокол LaLune).'));

        /* --- Секция: параметры --- */
        const s = m.section(form.NamedSection, 'config', 'csqtt', _('Параметры подключения'));

        let o = s.option(form.Value, 'link', _('CSQTT-ссылка'));
        o.rmempty = false;
        o.placeholder = 'csqtt://connect?v=2&host=...&peer=...&password=...&hashes=...';
        o.default = data.link;
        o.write = function (section_id, value) {
            localStorage.setItem(LS_LINK, value);
            return form.Value.prototype.write.apply(this, arguments);
        };

        o = s.option(form.Value, 'token', _('VK-токен'));
        o.password = true;
        o.rmempty = true;
        o.placeholder = 'vk1.a.xxxxx (необязательно)';
        o.default = data.token;
        o.write = function (section_id, value) {
            localStorage.setItem(LS_TOKEN, value);
            return form.Value.prototype.write.apply(this, arguments);
        };

        o = s.option(form.Value, 'hashes', _('Количество хешей'));
        o.datatype = 'range(1,6)';
        o.default = data.hashes;
        o.rmempty = false;
        o.description = _('От 1 до 6. По умолчанию: 3');
        o.write = function (section_id, value) {
            localStorage.setItem(LS_HASHES, value);
            return form.Value.prototype.write.apply(this, arguments);
        };

        o = s.option(form.Value, 'workers', _('Количество воркеров'));
        o.datatype = 'range(1,127)';
        o.default = data.workers;
        o.rmempty = false;
        o.description = _('От 1 до 127. По умолчанию: 27');
        o.write = function (section_id, value) {
            localStorage.setItem(LS_WORKERS, value);
            return form.Value.prototype.write.apply(this, arguments);
        };

        /* --- Секция: действия --- */
        const s2 = m.section(form.NamedSection, 'actions', 'actions', _('Действия'));

        o = s2.option(form.DummyValue, '_status', _('Статус'));
        o.rawhtml = true;
        o.cfgvalue = function () {
            return E('span', { id: 'csqtt-status' },
                data.status.connected ? _('Подключено') :
                data.status.running   ? _('Установка...') :
                                        _('Отключено'));
        };

        o = s2.option(form.Button, '_connect', _('Подключить'));
        o.inputtitle = _('Подключить');
        o.inputstyle = 'apply';
        o.onclick = function () {
            const link    = (localStorage.getItem(LS_LINK)    || '').trim();
            const token   = (localStorage.getItem(LS_TOKEN)   || '').trim();
            const hashes  = (localStorage.getItem(LS_HASHES)  || '3').trim();
            const workers = (localStorage.getItem(LS_WORKERS) || '27').trim();

            if (!link) {
                ui.addNotification(null, E('p', _('Введите csqtt:// ссылку')), 'error');
                return;
            }
            if (!link.startsWith('csqtt://')) {
                ui.addNotification(null, E('p', _('Ссылка должна начинаться с csqtt://')), 'error');
                return;
            }

            ui.showModal(_('Подключение...'), [
                E('p', { class: 'spinning' }, _('Запускаю установочный скрипт CSQTT...'))
            ]);

            return callConnect(link, hashes, workers, token).then(function () {
                ui.hideModal();
                ui.addNotification(null,
                    E('p', _('Установщик запущен. Смотрите вкладку «Логи».')), 'info');
                self.refreshStatus();
            }).catch(function (err) {
                ui.hideModal();
                ui.addNotification(null, E('p', _('Ошибка: ') + err), 'error');
            });
        };

        o = s2.option(form.Button, '_disconnect', _('Отключить'));
        o.inputtitle = _('Отключить');
        o.inputstyle = 'reset';
        o.onclick = function () {
            ui.showModal(_('Отключение...'), [
                E('p', { class: 'spinning' }, _('Останавливаю CSQTT...'))
            ]);
            return callDisconnect().then(function () {
                ui.hideModal();
                ui.addNotification(null, E('p', _('Отключено')), 'info');
                self.refreshStatus();
            }).catch(function (err) {
                ui.hideModal();
                ui.addNotification(null, E('p', _('Ошибка: ') + err), 'error');
            });
        };

        /* --- Секция: логи --- */
        const s3 = m.section(form.NamedSection, 'logs', 'logs', _('Логи установки'));

        o = s3.option(form.TextValue, '_logs', _('csqtt.log'));
        o.rows = 24;
        o.wrap = 'off';
        o.cfgvalue = function () { return _('Нажмите «Обновить», чтобы загрузить логи.'); };
        o.readonly = true;

        o = s3.option(form.Button, '_reload_logs', _('Обновить логи'));
        o.inputtitle = _('Обновить');
        o.inputstyle = 'reload';
        o.onclick = function () {
            return callLogs(300).then(function (res) {
                const el = document.querySelector('textarea[name="_logs"]');
                if (el) {
                    el.value = res.logs || '';
                    el.scrollTop = el.scrollHeight;
                }
                ui.addNotification(null, E('p', _('Логи обновлены')), 'info');
            });
        };

        /* --- Секция: поддержать --- */
        const s4 = m.section(form.NamedSection, 'support', 'support', _('Поддержать'));

        o = s4.option(form.DummyValue, '_support_text', '');
        o.rawhtml = true;
        o.cfgvalue = function () {
            return E('div', { style: 'line-height:1.7;font-size:14px;' }, [
                E('p', {}, [
                    E('strong', {}, 'LaLune (клиент):'),
                    E('br'),
                    E('span', {}, 'Telegram: '),
                    E('a', { href: 'https://t.me/Endlad7373', target: '_blank' }, '@Endlad7373')
                ]),
                E('p', {}, [
                    E('strong', {}, 'CSQTT (ядро, amurcanov):'),
                    E('br'),
                    E('span', {}, 'ЮMoney: '),
                    E('a', { href: 'https://yoomoney.ru/to/4100119505530465/100', target: '_blank' },
                      'yoomoney.ru/to/4100119505530465/100'),
                    E('br'),
                    E('span', {}, 'GRAM (TON): '),
                    E('code', {}, 'UQCsHSj_Bev5AG3vCz-84TQC7BSwjNdNdoJp9M2gWUEmbyD7'),
                    E('br'),
                    E('span', {}, 'USDT (TON): '),
                    E('code', {}, 'UQCsHSj_Bev5AG3vCz-84TQC7BSwjNdNdoJp9M2gWUEmbyD7'),
                    E('br'),
                    E('span', {}, 'USDT (TRC20): '),
                    E('code', {}, 'TD1oiQiHmjqsRDPxfUjUbSWxEmcr4k7Lob')
                ]),
                E('p', { style: 'opacity:0.7;font-size:12px;' },
                  'Проект распространяется по лицензии PolyForm Noncommercial 1.0.0. ' +
                  'Коммерческое использование запрещено.')
            ]);
        };

        /* --- Polling --- */
        poll.add(L.bind(function () { return this.refreshStatus(); }, this), 5);

        return m.render();
    },

    refreshStatus: function () {
        return callStatus().then(function (res) {
            let raw = { running: false, pid: 0, connected: false, core_running: false };
            try { raw = JSON.parse(res.raw || '{}'); } catch (e) {}
            const el = document.getElementById('csqtt-status');
            if (el) {
                el.textContent = raw.connected ? _('Подключено')
                              : raw.running   ? _('Установка...')
                                              : _('Отключено');
                el.style.color = raw.connected ? '#2e7d32'
                              : raw.running   ? '#f9a825'
                                              : '#c62828';
            }
        });
    },

    handleSave: null,
    handleSaveApply: null,
    handleReset: null
});
