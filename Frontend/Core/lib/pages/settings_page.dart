import 'package:flutter/material.dart';

import '../api.dart';
import '../widgets/glass_card.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Settings _s = Settings();
  bool _loading = true;
  bool _busy = false;

  final _workersCtl = TextEditingController();
  final _clientIdsCtl = TextEditingController();
  final _deviceIdCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _workersCtl.dispose();
    _clientIdsCtl.dispose();
    _deviceIdCtl.dispose();
    super.dispose();
  }

  void _load() {
    final s = Api.getSettings();
    setState(() {
      _s = s;
      _workersCtl.text = s.workersPerHash.toString();
      _clientIdsCtl.text = s.clientIds;
      _deviceIdCtl.text = s.deviceId;
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final s = Settings(
      peer: _s.peer,
      vkHashes: _s.vkHashes,
      password: _s.password,
      workersPerHash: int.tryParse(_workersCtl.text) ?? 9,
      obfs: _s.obfs,
      fingerprint: _s.fingerprint,
      clientIds: _clientIdsCtl.text,
      deviceId: _s.deviceId,
    );
    final ok = Api.saveSettings(s);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Настройки сохранены' : 'Ошибка сохранения'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.black.withOpacity(0.8),
      ),
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
                    _rowInput(
                      label: 'Workers on hash',
                      controller: _workersCtl,
                      keyboardType: TextInputType.number,
                    ),
                    _rowInput(
                      label: 'Client IDs',
                      controller: _clientIdsCtl,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _sectionTitle('Device ID'),
              GlassCard(
                child: Column(
                  children: [
                    _rowInput(
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
                          side: BorderSide(
                            color: Colors.white.withOpacity(0.2),
                          ),
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

  Widget _rowInput({
    required String label,
    required TextEditingController controller,
    TextInputType? keyboardType,
    bool readOnly = false,
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
            child: TextField(
              controller: controller,
              keyboardType: keyboardType,
              readOnly: readOnly,
              style: const TextStyle(fontSize: 13.5),
            ),
          ),
        ],
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
