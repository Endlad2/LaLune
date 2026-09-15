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

  // Выбранный конфиг для авто-заполнения Peer/Password/Hashes
  int? _selectedConfigId;

  // Управляемые контроллеры
  final _peerCtl = TextEditingController();
  final _vkHashesCtl = TextEditingController();
  final _passwordCtl = TextEditingController();
  final _workersCtl = TextEditingController();
  final _clientIdsCtl = TextEditingController();
  final _deviceIdCtl = TextEditingController();

  // Авторизация
  String _authMode = 'manual'; // 'manual' | 'autoApi' | 'autoVk'

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _peerCtl.dispose();
    _vkHashesCtl.dispose();
    _passwordCtl.dispose();
    _workersCtl.dispose();
    _clientIdsCtl.dispose();
    _deviceIdCtl.dispose();
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

    // Если есть конфиг, совпадающий по peer — выделяем его
    _selectedConfigId = null;
    for (final c in cfgs) {
      if (c.peer == s.peer && c.password == s.password) {
        _selectedConfigId = c.id;
        break;
      }
    }

    setState(() => _loading = false);
  }

  /// Применяет конфиг к полям формы.
  void _applyConfig(ConfigItem c) {
    setState(() {
      _selectedConfigId = c.id;
      _peerCtl.text = c.peer;
      _passwordCtl.text = c.password;
      // У некоторых конфигов hashes пустой — тогда оставляем как есть
      if (c.hashes.isNotEmpty) {
        _vkHashesCtl.text = c.hashes;
      }
    });
  }

  /// Регенерация списка конфигов и обновление выбранного.
  void _refreshConfigs() {
    final cfgs = Api.getConfigs();
    setState(() => _configs = cfgs);
  }

  Future<void> _save() async {
    setState(() => _busy = true);

    final s = Settings(
      peer: _peerCtl.text.trim(),
      vkHashes: _vkHashesCtl.text.trim(),
      password: _passwordCtl.text,
      workersPerHash: int.tryParse(_workersCtl.text) ?? 9,
      obfs: _s.obfs,
      fingerprint: _s.fingerprint,
      clientIds: _clientIdsCtl.text.trim(),
      deviceId: _s.deviceId,
    );

    final ok = Api.saveSettings(s);
    if (!mounted) return;
    setState(() => _busy = false);

    Toast.show(
      context,
      ok ? 'Настройки сохранены' : 'Ошибка сохранения настроек',
      isError: !ok,
    );
  }

  void _regenDeviceId() {
    final id = Api.regenerateDeviceId();
    if (id.isNotEmpty) {
      setState(() {
        _s = Settings(
          peer: _s.peer,
          vkHashes: _s.vkHashes,
          password: _s.password,
          workersPerHash: _s.workersPerHash,
          obfs: _s.obfs,
          fingerprint: _s.fingerprint,
          clientIds: _s.clientIds,
          deviceId: id,
        );
        _deviceIdCtl.text = id;
      });
    }
  }

  // ============================================================
  //  Авторизация
  // ============================================================

  void _setAuthMode(String mode) {
    setState(() => _authMode = mode);
    if (mode != 'manual') {
      Toast.show(context, 'Авторизация в разработке');
    }
  }

  void _onLoginTap() {
    Toast.show(context, 'Функционал не реализован', isError: true);
  }

  Widget _buildAuthBlock() {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'РЕЖИМ АВТОРИЗАЦИИ',
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.7,
              fontWeight: FontWeight.w700,
              color: Colors.white.withOpacity(0.4),
            ),
          ),
          const SizedBox(height: 10),

          _authOption(
            value: 'manual',
            title: 'Ручной',
            subtitle: 'Ввести хеши вручную',
          ),
          _authOption(
            value: 'autoApi',
            title: 'Авто API',
            subtitle: 'Получать хеши через публичное API',
          ),
          _authOption(
            value: 'autoVk',
            title: 'Авто ВК',
            subtitle: 'Автоматически через VK',
          ),

          if (_authMode == 'manual') ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Хеши (через запятую или +)',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withOpacity(0.65),
                ),
              ),
            ),
            TextField(
              controller: _vkHashesCtl,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'hash1,hash2,hash3',
              ),
            ),
          ] else ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _onLoginTap,
                icon: const Icon(Icons.login, size: 16),
                label: const Text('Войти'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withOpacity(0.2)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _authOption({
    required String value,
    required String title,
    required String subtitle,
  }) {
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
            color: selected
                ? const Color(0xFF4A6CF7).withOpacity(0.18)
                : Colors.white.withOpacity(0.02),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? const Color(0xFF4A6CF7).withOpacity(0.55)
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
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.white.withOpacity(0.55),
                      ),
                    ),
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
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ============ ОСНОВНЫЕ НАСТРОЙКИ ============
              _sectionTitle('Основные настройки'),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Выбор конфига
                    if (_configs.isNotEmpty) ...[
                      Text(
                        'Конфиг',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.65),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _configDropdown(),
                      const SizedBox(height: 8),
                      Divider(
                          color: Colors.white.withOpacity(0.08), height: 16),
                    ],

                    InputRow(label: 'Peer', controller: _peerCtl),
                    InputRow(label: 'Password', controller: _passwordCtl),
                    InputRow(
                      label: 'Workers on hash',
                      controller: _workersCtl,
                      keyboardType: TextInputType.number,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // ============ АВТОРИЗАЦИЯ ============
              _sectionTitle('Авторизация'),
              _buildAuthBlock(),
              const SizedBox(height: 18),

              // ============ ПРОДВИНУТЫЕ ============
              _sectionTitle('Продвинутые настройки'),
              GlassCard(
                child: Column(
                  children: [
                    _rowDropdown(
                      label: 'Obfs',
                      value: _s.obfs,
                      items: const ['video', 'audio'],
                      onChanged: (v) => setState(() {
                        _s = Settings(
                          peer: _s.peer,
                          vkHashes: _s.vkHashes,
                          password: _s.password,
                          workersPerHash: _s.workersPerHash,
                          obfs: v,
                          fingerprint: _s.fingerprint,
                          clientIds: _s.clientIds,
                          deviceId: _s.deviceId,
                        );
                      }),
                    ),
                    _rowDropdown(
                      label: 'Fingerprint',
                      value: _s.fingerprint,
                      items: const ['firefox', 'chrome', 'edge'],
                      onChanged: (v) => setState(() {
                        _s = Settings(
                          peer: _s.peer,
                          vkHashes: _s.vkHashes,
                          password: _s.password,
                          workersPerHash: _s.workersPerHash,
                          obfs: _s.obfs,
                          fingerprint: v,
                          clientIds: _s.clientIds,
                          deviceId: _s.deviceId,
                        );
                      }),
                    ),
                    InputRow(label: 'Client IDs', controller: _clientIdsCtl),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // ============ DEVICE ID ============
              _sectionTitle('Device ID'),
              GlassCard(
                child: Column(
                  children: [
                    InputRow(
                      label: 'Device ID',
                      controller: _deviceIdCtl,
                      readOnly: true,
                    ),
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
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
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
          hint: Text(
            'Не выбран',
            style: TextStyle(color: Colors.white.withOpacity(0.55)),
          ),
          items: [
            for (final c in _configs)
              DropdownMenuItem<int?>(
                value: c.id,
                child: Text(
                  c.name.isEmpty ? c.peer : c.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
          ],
          onChanged: (id) {
            if (id == null) return;
            final c = _configs.firstWhere((e) => e.id == id,
                orElse: () => _configs.first);
            _applyConfig(c);
          },
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: Colors.white.withOpacity(0.55),
        ),
      ),
    );
  }

  Widget _rowDropdown({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: TextStyle(color: Colors.white.withOpacity(0.7))),
          ),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: items.contains(value) ? value : items.first,
              dropdownColor: const Color(0xFF0F1540),
              items: items
                  .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                  .toList(),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}
