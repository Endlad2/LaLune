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
  List<ConfigItem> _configs = [];
  bool _loading = true;
  bool _busy = false;
  int? _selectedConfigId;

  final _peerCtl = TextEditingController();
  final _vkHashesCtl = TextEditingController();
  final _passwordCtl = TextEditingController();
  final _workersCtl = TextEditingController();
  final _clientIdsCtl = TextEditingController();
  final _deviceIdCtl = TextEditingController();
  final _turnHostCtl = TextEditingController();
  final _turnPortCtl = TextEditingController();

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
    _clientIdsCtl.dispose();
    _deviceIdCtl.dispose();
    _turnHostCtl.dispose();
    _turnPortCtl.dispose();
    super.dispose();
  }

  void _load() {
    final s = Api.getSettings();
    final cfgs = Api.getConfigs();

    _s = s;
    _configs = cfgs;

    _peerCtl.text = s.peer;
    _vkHashesCtl.text = s.vkHashes;
    _passwordCtl.text = s.password;
    _workersCtl.text = s.workersPerHash.toString();
    _clientIdsCtl.text = s.clientIds;
    _deviceIdCtl.text = s.deviceId;
    _turnHostCtl.text = s.turnHost;
    _turnPortCtl.text = s.turnPort;
    _authMode = s.authMode.isEmpty ? 'manual' : s.authMode;

    _selectedConfigId = null;
    for (final c in cfgs) {
      if (c.peer == s.peer && c.password == s.password) {
        _selectedConfigId = c.id;
        break;
      }
    }

    _vkState = Api.getVKTokenState();
    setState(() => _loading = false);
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

  void _applyConfig(ConfigItem c) {
    setState(() {
      _selectedConfigId = c.id;
      _peerCtl.text = c.peer;
      _passwordCtl.text = c.password;
      if (c.hashes.isNotEmpty) _vkHashesCtl.text = c.hashes;
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);

    final s = _s.copyWith(
      peer: _peerCtl.text.trim(),
      vkHashes: _vkHashesCtl.text.trim(),
      vkJsToken: _s.vkJsToken,
      password: _passwordCtl.text,
      workersPerHash: int.tryParse(_workersCtl.text) ?? 9,
      clientIds: _clientIdsCtl.text.trim(),
      deviceId: _s.deviceId,
      authMode: _authMode,
      turnHost: _turnHostCtl.text.trim(),
      turnPort: _turnPortCtl.text.trim(),
    );

    final ok = Api.saveSettings(s);
    if (!mounted) return;
    setState(() { _busy = false; _s = s; });

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
      });
    }
  }

  // ============================================================
  //  Авторизация
  // ============================================================

  void _setAuthMode(String mode) {
    setState(() => _authMode = mode);
    if (mode == 'autoApi' || mode == 'autoVk') {
      if (!_vkState.hasToken) {
        Toast.show(context, 'Сначала войдите в ВК', isError: true);
      }
    }
  }

  Future<void> _onLoginTap() async {
    if (_vkLoginInProgress) return;
    _vkLoginInProgress = true;

    Toast.show(context, 'Запускаю LaLuneTokenFetcher...');

    final started = Api.loginVK();
    if (!started) {
      _vkLoginInProgress = false;
      Toast.show(context, 'Не удалось запустить fetcher', isError: true);
      return;
    }

    for (var i = 0; i < 600; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final st = Api.getVKTokenState();
      setState(() => _vkState = st);
      if (st.hasToken) {
        Toast.show(context, 'Поздравляем, токен ВК получен успешно');
        _vkLoginInProgress = false;
        return;
      }
      if (!st.fetching && i > 4) break;
    }

    _vkLoginInProgress = false;
    if (!_vkState.hasToken) {
      Toast.show(context, 'Авторизация не завершена', isError: true);
    }
  }

  Widget _buildAuthBlock() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('РЕЖИМ АВТОРИЗАЦИИ',
            style: TextStyle(fontSize: 10.5, letterSpacing: 0.7,
              fontWeight: FontWeight.w700, color: Colors.white.withOpacity(0.4))),
          const SizedBox(height: 10),

          _authOption('manual', 'Ручной', 'Ввести хеши вручную'),
          _authOption('autoApi', 'Авто API', 'Создавать звонки через VK API'),
          _authOption('autoVk', 'Авто ВК', 'Ядро само авторизуется через VK'),

          const SizedBox(height: 12),

          if (!_vkState.hasToken)
            _buildLoginButton()
          else
            _buildTokenOkBadge(),

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
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLoginButton() {
    if (_vkState.fetching) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: null,
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

  Widget _buildTokenOkBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF7CFF9A).withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF7CFF9A).withOpacity(0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle, size: 18, color: Color(0xFF7CFF9A)),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Токен ВК получен',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            onPressed: () {
              Api.deleteVKToken();
              setState(() => _vkState = VkTokenState.empty);
              Toast.show(context, 'Токен ВК удалён');
            },
            icon: const Icon(Icons.delete_outline, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _authOption(String value, String title, String subtitle) {
    final selected = _authMode == value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: () => _setAuthMode(value),
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
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 18,
                color: selected ? const Color(0xFF4A6CF7) : Colors.white.withOpacity(0.4)),
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
            ],
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
                    if (_configs.isNotEmpty) ...[
                      Text('Конфиг',
                        style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.65))),
                      const SizedBox(height: 6),
                      _configDropdown(),
                      const SizedBox(height: 8),
                      Divider(color: Colors.white.withOpacity(0.08), height: 16),
                    ],
                    InputRow(label: 'Peer', controller: _peerCtl),
                    InputRow(label: 'Password', controller: _passwordCtl),
                    InputRow(label: 'Workers on hash', controller: _workersCtl,
                      keyboardType: TextInputType.number),
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
                      (v) => setState(() => _s = _s.copyWith(obfs: v))),
                    _rowDropdown('Fingerprint', _s.fingerprint,
                      const ['firefox', 'chrome', 'edge'],
                      (v) => setState(() => _s = _s.copyWith(fingerprint: v))),
                    _rowDropdown('Captcha Mode', _s.captchaMode,
                      const ['auto', 'wv', 'rjs'],
                      (v) => setState(() => _s = _s.copyWith(captchaMode: v))),
                    _rowDropdown('Turn Transport', _s.turnTransport,
                      const ['udp', 'tcp'],
                      (v) => setState(() => _s = _s.copyWith(turnTransport: v))),
                    InputRow(label: 'Turn Host', controller: _turnHostCtl),
                    InputRow(label: 'Turn Port', controller: _turnPortCtl),
                    InputRow(label: 'Client IDs', controller: _clientIdsCtl),
                    _toggleRow('Allow hash redistribution', _s.allowHashRedistribution,
                      (v) => setState(() => _s = _s.copyWith(allowHashRedistribution: v))),
                    _toggleRow('Validate VK hashes', _s.validateVkHashes,
                      (v) => setState(() => _s = _s.copyWith(validateVkHashes: v))),
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

  Widget _configDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int?>(
          value: _selectedConfigId,
          isExpanded: true,
          dropdownColor: const Color(0xFF0F1540),
          iconEnabledColor: Colors.white70,
          hint: Text('Не выбран', style: TextStyle(color: Colors.white.withOpacity(0.55))),
          items: [
            for (final c in _configs)
              DropdownMenuItem<int?>(value: c.id,
                child: Text(c.name.isEmpty ? c.peer : c.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5))),
          ],
          onChanged: (id) {
            if (id == null) return;
            final c = _configs.firstWhere((e) => e.id == id, orElse: () => _configs.first);
            _applyConfig(c);
          },
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
