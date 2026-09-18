import 'dart:async';
import 'package:flutter/material.dart';

import '../api.dart';
import '../widgets/glass_card.dart';
import '../widgets/input_row.dart';
import '../widgets/toast.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Settings _s = Settings();
  ConfigItem? _selectedConfig;
  bool _loading = true;
  bool _busy = false;
  bool _dirty = false;

  final _peerCtl = TextEditingController();
  final _vkHashesCtl = TextEditingController();
  final _passwordCtl = TextEditingController();
  final _workersCtl = TextEditingController();
  final _autoApiWorkersCtl = TextEditingController();
  final _clientIdsCtl = TextEditingController();
  final _deviceIdCtl = TextEditingController();

  String _authMode = 'manual';
  VkTokenState _vkState = VkTokenState.empty;
  Timer? _vkPollTimer;
  bool _vkLoginInProgress = false;

  @override
  void initState() {
    super.initState();
    _load();
    _startVkPolling();
  }

  @override
  void dispose() {
    _vkPollTimer?.cancel();
    _peerCtl.dispose();
    _vkHashesCtl.dispose();
    _passwordCtl.dispose();
    _workersCtl.dispose();
    _autoApiWorkersCtl.dispose();
    _clientIdsCtl.dispose();
    _deviceIdCtl.dispose();
    super.dispose();
  }

  void _load() {
    final s = Api.getSettings();

    var cfg = SelectedConfig.current;
    if (cfg == null) {
      cfg = Api.loadSelectedConfigFromJs();
      if (cfg != null) SelectedConfig.set(cfg);
    }
    _selectedConfig = cfg;

    _s = s;

    if (cfg != null) {
      _peerCtl.text = cfg.peer;
      _passwordCtl.text = cfg.password;
      _vkHashesCtl.text = cfg.hashes;
    } else {
      _peerCtl.text = s.peer;
      _passwordCtl.text = s.password;
      _vkHashesCtl.text = s.vkHashes;
    }

    _workersCtl.text = s.workers.toString();
    _autoApiWorkersCtl.text = s.autoApiWorkers.toString();
    _clientIdsCtl.text = s.clientIds;
    _deviceIdCtl.text = s.deviceId;
    _authMode = s.authMode.isEmpty ? 'manual' : s.authMode;

    _vkState = Api.validateVKToken();
    setState(() {
      _loading = false;
      _dirty = false;
    });
  }

  void _markDirty() {
    _dirty = true;
    if (!mounted) return;
    Toast.show(
      context,
      'Сохраните настройки!',
      isError: true,
      duration: const Duration(seconds: 2),
    );
  }

  void _startVkPolling() {
    _vkPollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final st = Api.getVKTokenState();
      if (st.hasToken != _vkState.hasToken ||
          st.fetching != _vkState.fetching ||
          st.progress != _vkState.progress ||
          st.message != _vkState.message) {
        setState(() => _vkState = st);
      }
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);

    final cfg = _selectedConfig;

    var w = int.tryParse(_workersCtl.text) ?? kDefaultWorkers;
    if (w < kMinWorkers) w = kMinWorkers;
    if (w > kMaxWorkers) w = kMaxWorkers;

    var aw = int.tryParse(_autoApiWorkersCtl.text) ?? kDefaultAutoApiWorkers;
    if (aw < kMinAutoApiWorkers) aw = kMinAutoApiWorkers;
    if (aw > kMaxAutoApiWorkers) aw = kMaxAutoApiWorkers;

    _workersCtl.text = w.toString();
    _autoApiWorkersCtl.text = aw.toString();

    final s = _s.copyWith(
      peer: cfg?.peer ?? _peerCtl.text.trim(),
      vkHashes: cfg?.hashes ?? _vkHashesCtl.text.trim(),
      password: cfg?.password ?? _passwordCtl.text,
      workers: w,
      autoApiWorkers: aw,
      clientIds: _clientIdsCtl.text.trim(),
      deviceId: _s.deviceId,
      authMode: _authMode,
    );

    final ok = Api.saveSettings(s);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _s = s;
      _dirty = false;
    });

    Toast.show(context,
        ok ? 'Настройки сохранены' : 'Ошибка сохранения настроек',
        isError: !ok);
  }

  void _regenDeviceId() {
    final id = Api.regenerateDeviceId();
    if (id.isNotEmpty) {
      setState(() {
        _deviceIdCtl.text = id;
        _s = _s.copyWith(deviceId: id);
        _dirty = true;
      });
    }
  }

  // ============================================================
  //  Авторизация
  // ============================================================

  void _setAuthMode(String mode) {
    if (mode == 'autoApi' || mode == 'autoVk') {
      final st = Api.validateVKToken();
      setState(() => _vkState = st);
      if (!st.hasToken) {
        Toast.show(context, 'Требуется авторизация ВК', isError: true);
        return;
      }
    }
    setState(() => _authMode = mode);
    _markDirty();
  }

  Future<void> _onLoginTap() async {
    // Даже если уже идёт процесс — позволяем перезапустить.
    // Если токен есть — не перезапускаем, показываем сообщение.
    final st = Api.validateVKToken();
    setState(() => _vkState = st);
    if (st.hasToken) {
      Toast.show(context, 'Токен ВК уже активен');
      return;
    }

    _vkLoginInProgress = true;
    Toast.show(context, 'Открываю авторизацию ВК...');

    final started = Api.vkLogin();
    if (!started) {
      _vkLoginInProgress = false;
      Toast.show(context, 'Не удалось запустить авторизацию', isError: true);
      return;
    }

    for (var i = 0; i < 600; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final cur = Api.validateVKToken();
      setState(() => _vkState = cur);
      if (cur.hasToken) {
        Toast.show(context, 'Поздравляем, токен ВК получен успешно');
        _vkLoginInProgress = false;
        return;
      }
      if (!cur.fetching && i > 4) break;
    }

    _vkLoginInProgress = false;
    if (!_vkState.hasToken) {
      Toast.show(context, 'Авторизация не завершена', isError: true);
    }
  }

  Widget _buildAuthBlock() {
    final hasToken = _vkState.hasToken;
    final isAutoApi = _authMode == 'autoApi';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('РЕЖИМ АВТОРИЗАЦИИ',
                style: TextStyle(fontSize: 10.5, letterSpacing: 0.7,
                  fontWeight: FontWeight.w700, color: Colors.white.withOpacity(0.4))),
              const SizedBox(height: 10),

              _authOption('manual', 'Ручной', 'Ввести хеши вручную', enabled: true),
              _authOption('autoApi', 'Авто API', 'Создавать звонки через VK API',
                  enabled: hasToken),
              _authOption('autoVk', 'Авто ВК', 'Ядро само авторизуется через VK',
                  enabled: hasToken),

              const SizedBox(height: 12),

              if (!hasToken)
                _buildLoginButton()
              else
                _buildTokenActiveBadge(),

              if (_vkState.fetching) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: _vkState.progress / 100.0,
                  backgroundColor: Colors.white.withOpacity(0.1),
                  valueColor: const AlwaysStoppedAnimation(Color(0xFFF7E84E)),
                  minHeight: 4,
                ),
                const SizedBox(height: 6),
                Text(_vkState.message,
                  style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.6))),
              ],

              // Доп. подсказка: жёлтый фон.
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7E84E).withOpacity(0.14),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFFF7E84E).withOpacity(0.55),
                    width: 1,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.tips_and_updates_outlined,
                        size: 16, color: Color(0xFFF7E84E)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Если зависло получение токена — нажмите на «Войти» заново',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.45,
                          color: Colors.white.withOpacity(0.85),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              if (_authMode == 'manual') ...[
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('Хеши (через запятую или +)',
                    style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.65))),
                ),
                TextField(
                  controller: _vkHashesCtl,
                  minLines: 2, maxLines: 4,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(hintText: 'hash1,hash2,hash3'),
                  onChanged: (_) => _markDirty(),
                ),
              ],
            ],
          ),
        ),

        if (isAutoApi) ...[
          const SizedBox(height: 14),
          _buildAutoApiBlock(),
        ],
      ],
    );
  }

  Widget _buildAutoApiBlock() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('АВТО API',
            style: TextStyle(fontSize: 10.5, letterSpacing: 0.7,
              fontWeight: FontWeight.w700, color: Colors.white.withOpacity(0.4))),
          const SizedBox(height: 10),

          Row(
            children: [
              SizedBox(
                width: 170,
                child: Text('Воркеров на хеш',
                  style: TextStyle(color: Colors.white.withOpacity(0.7))),
              ),
              Expanded(
                child: TextField(
                  controller: _autoApiWorkersCtl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(
                    hintText: '9',
                    helperText: 'От 9 до 27',
                    helperStyle: TextStyle(fontSize: 10.5),
                  ),
                  onChanged: (_) => _markDirty(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLoginButton() {
    if (_vkState.fetching) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          // Оставляем активной — чтобы можно было перезапустить, если зависло.
          onPressed: _vkLoginInProgress ? null : _onLoginTap,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text('Ожидание... ${_vkState.progress}%'),
            ],
          ),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _vkLoginInProgress ? null : _onLoginTap,
        icon: const Icon(Icons.login, size: 16),
        label: const Text('Войти'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: BorderSide(color: Colors.white.withOpacity(0.2)),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  Widget _buildTokenActiveBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF7CFF9A).withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF7CFF9A).withOpacity(0.45)),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text('Активно',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            tooltip: 'Сбросить токен',
            onPressed: () {
              Api.deleteVKToken();
              setState(() {
                _vkState = VkTokenState.empty;
                if (_authMode == 'autoApi' || _authMode == 'autoVk') {
                  _authMode = 'manual';
                }
              });
              Toast.show(context, 'Токен ВК удалён');
            },
            icon: const Icon(Icons.delete_outline, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _authOption(String value, String title, String subtitle,
      {required bool enabled}) {
    final selected = _authMode == value;
    final opacity = enabled ? 1.0 : 0.4;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Opacity(
        opacity: opacity,
        child: InkWell(
          onTap: enabled ? () => _setAuthMode(value) : null,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF4A6CF7).withOpacity(0.18)
                : Colors.white.withOpacity(0.02),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? const Color(0xFF4A6CF7).withOpacity(0.55)
                  : Colors.white.withOpacity(0.08),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 18,
                  color: selected
                      ? const Color(0xFF4A6CF7)
                      : Colors.white.withOpacity(0.4),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                      Text(subtitle, style: TextStyle(fontSize: 11.5, color: Colors.white.withOpacity(0.55))),
                    ],
                  ),
                ),
                if (!enabled)
                  Icon(Icons.lock_outline,
                      size: 14, color: Colors.white.withOpacity(0.5)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  //  UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sectionTitle('Основные настройки'),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_selectedConfig != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            const Icon(Icons.link, size: 14,
                                color: Color(0xFF7CFF9A)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Конфиг: ${_selectedConfig!.name.isEmpty ? _selectedConfig!.peer : _selectedConfig!.name}',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: Colors.white.withOpacity(0.75),
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          'Конфиг не выбран. Выберите во вкладке «Подключение».',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withOpacity(0.55),
                          ),
                        ),
                      ),

                    InputRow(label: 'Peer', controller: _peerCtl, readOnly: true),
                    InputRow(label: 'Password', controller: _passwordCtl, readOnly: true),

                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 130,
                            child: Text('Workers',
                              style: TextStyle(color: Colors.white.withOpacity(0.7))),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _workersCtl,
                              keyboardType: TextInputType.number,
                              style: const TextStyle(fontSize: 13.5),
                              decoration: const InputDecoration(
                                hintText: '9',
                                helperText: 'От 1 до 127',
                                helperStyle: TextStyle(fontSize: 10.5),
                              ),
                              onChanged: (_) => _markDirty(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              _sectionTitle('Авторизация'),
              _buildAuthBlock(),
              const SizedBox(height: 18),

              _sectionTitle('Продвинутые настройки'),
              GlassCard(
                child: Column(
                  children: [
                    _rowDropdown('Obfs', _s.obfs, const ['video', 'audio'],
                      (v) {
                        setState(() => _s = _s.copyWith(obfs: v));
                        _markDirty();
                      }),
                    _rowDropdown('Fingerprint', _s.fingerprint,
                      const ['firefox', 'chrome', 'edge'],
                      (v) {
                        setState(() => _s = _s.copyWith(fingerprint: v));
                        _markDirty();
                      }),
                    _rowDropdown('Captcha Mode', _s.captchaMode,
                      const ['auto', 'wv', 'rjs'],
                      (v) {
                        setState(() => _s = _s.copyWith(captchaMode: v));
                        _markDirty();
                      }),
                    _rowDropdown('Turn Transport', _s.turnTransport,
                      const ['udp', 'tcp'],
                      (v) {
                        setState(() => _s = _s.copyWith(turnTransport: v));
                        _markDirty();
                      }),
                    InputRow(label: 'Client IDs', controller: _clientIdsCtl,
                      onChanged: (_) => _markDirty()),
                    _toggleRow('Allow hash redistribution', _s.allowHashRedistribution,
                      (v) {
                        setState(() => _s = _s.copyWith(allowHashRedistribution: v));
                        _markDirty();
                      }),
                    _toggleRow('Validate VK hashes', _s.validateVkHashes,
                      (v) {
                        setState(() => _s = _s.copyWith(validateVkHashes: v));
                        _markDirty();
                      }),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              _sectionTitle('Device ID'),
              GlassCard(
                child: Column(
                  children: [
                    InputRow(label: 'Device ID', controller: _deviceIdCtl, readOnly: true),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _regenDeviceId,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Перегенерировать'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(color: Colors.white.withOpacity(0.2)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),

              ElevatedButton(
                onPressed: _busy ? null : _save,
                child: Text(_busy ? 'Сохранение...' : 'Сохранить настройки'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
        letterSpacing: 0.6, color: Colors.white.withOpacity(0.55))),
    );
  }

  Widget _rowDropdown(String label, String value, List<String> items,
      ValueChanged<String> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(width: 150,
            child: Text(label, style: TextStyle(color: Colors.white.withOpacity(0.7)))),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: items.contains(value) ? value : items.first,
              dropdownColor: const Color(0xFF0F1540),
              items: items.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
              onChanged: (v) { if (v != null) onChanged(v); },
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggleRow(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: Colors.white.withOpacity(0.7))),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: const Color(0xFFF7E84E),
          ),
        ],
      ),
    );
  }
}
