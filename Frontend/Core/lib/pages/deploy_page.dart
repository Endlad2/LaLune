import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart';
import '../widgets/glass_card.dart';

/// Вкладка "Деплой": ставит выбранный протокол (core) на удалённый сервер
/// по SSH через Core/DeployManager (Rust-бинарь).
class DeployPage extends StatefulWidget {
  const DeployPage({super.key});

  @override
  State<DeployPage> createState() => _DeployPageState();
}

class _DeployPageState extends State<DeployPage> {
  static const List<String> _protocols = <String>[
    'CSQTT',
    'FreeTurn',
    'OlcRTC',
    'OpenFlux',
    'ToTS',
  ];

  String _protocol = 'CSQTT';
  final TextEditingController _host = TextEditingController();
  final TextEditingController _sshPort = TextEditingController(text: '22');
  final TextEditingController _user = TextEditingController(text: 'root');
  final TextEditingController _password = TextEditingController();
  final TextEditingController _keyPath = TextEditingController();

  // Ручные порты.
  bool _manualPorts = false;
  final TextEditingController _corePort = TextEditingController();
  final TextEditingController _warpPort = TextEditingController();
  final TextEditingController _listenPort = TextEditingController();

  // Режим авторизации: true = пароль, false = SSH-ключ.
  bool _usePassword = true;

  bool _deploying = false;
  String _log = '';
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _startPolling();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _host.dispose();
    _sshPort.dispose();
    _user.dispose();
    _password.dispose();
    _keyPath.dispose();
    _corePort.dispose();
    _warpPort.dispose();
    _listenPort.dispose();
    super.dispose();
  }

  void _startPolling() {
    _poll = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (!mounted) return;
      final busy = Api.isDeploying();
      final log = Api.deployLog();
      if (busy != _deploying || log != _log) {
        setState(() {
          _deploying = busy;
          _log = log;
        });
      }
    });
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.black.withOpacity(0.85),
      ),
    );
  }

  void _startDeploy() {
    final host = _host.text.trim();
    if (host.isEmpty) {
      _showToast('Укажите IP/хост сервера');
      return;
    }
    if (_usePassword && _password.text.isEmpty) {
      _showToast('Укажите пароль');
      return;
    }
    if (!_usePassword && _keyPath.text.trim().isEmpty) {
      _showToast('Укажите путь к SSH-ключу');
      return;
    }

    final payload = <String, dynamic>{
      'protocol': _protocol,
      'host': host,
      'sshPort': int.tryParse(_sshPort.text.trim()) ?? 22,
      'user': _user.text.trim().isEmpty ? 'root' : _user.text.trim(),
      'usePassword': _usePassword,
      'password': _usePassword ? _password.text : '',
      'keyPath': _usePassword ? '' : _keyPath.text.trim(),
      'manualPorts': _manualPorts,
      'corePort': int.tryParse(_corePort.text.trim()) ?? 0,
      'warpPort': int.tryParse(_warpPort.text.trim()) ?? 0,
      'listenPort': int.tryParse(_listenPort.text.trim()) ?? 0,
    };

    setState(() => _deploying = true);
    final ok = Api.deploy(jsonEncode(payload));
    if (!ok) {
      setState(() => _deploying = false);
      _showToast('Не удалось запустить деплой');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            children: [
              const Text(
                'Деплой на сервер',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFF7E84E),
                ),
              ),
              const SizedBox(height: 16),

              _block('Протокол', [
                DropdownButtonFormField<String>(
                  value: _protocol,
                  dropdownColor: const Color(0xFF0F1540),
                  decoration: _inputDecoration('Протокол для деплоя'),
                  items: _protocols
                      .map((p) => DropdownMenuItem<String>(
                            value: p,
                            child: Text(p),
                          ))
                      .toList(),
                  onChanged: _deploying
                      ? null
                      : (v) => setState(() => _protocol = v ?? 'CSQTT'),
                ),
              ]),

              _block('Данные сервера', [
                TextField(
                  controller: _host,
                  enabled: !_deploying,
                  decoration: _inputDecoration('IP / хост (например 1.2.3.4)'),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _sshPort,
                        enabled: !_deploying,
                        keyboardType: TextInputType.number,
                        decoration: _inputDecoration('SSH порт'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _user,
                        enabled: !_deploying,
                        decoration: _inputDecoration('Пользователь'),
                      ),
                    ),
                  ],
                ),
              ]),

              _block('Авторизация', [
                Row(
                  children: [
                    _modeChip('Пароль', _usePassword, () {
                      if (!_deploying) setState(() => _usePassword = true);
                    }),
                    const SizedBox(width: 8),
                    _modeChip('SSH-ключ', !_usePassword, () {
                      if (!_deploying) setState(() => _usePassword = false);
                    }),
                  ],
                ),
                const SizedBox(height: 12),
                if (_usePassword)
                  TextField(
                    controller: _password,
                    enabled: !_deploying,
                    obscureText: true,
                    decoration: _inputDecoration('Пароль'),
                  )
                else
                  TextField(
                    controller: _keyPath,
                    enabled: !_deploying,
                    decoration:
                        _inputDecoration('Путь к SSH-ключу (id_rsa)'),
                  ),
              ]),

              _block('Порты', [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: const Color(0xFFF7E84E),
                  value: _manualPorts,
                  onChanged: _deploying
                      ? null
                      : (v) => setState(() => _manualPorts = v),
                  title: const Text('Ручные порты'),
                  subtitle: Text(
                    _manualPorts
                        ? 'Задайте порты вручную'
                        : 'Автоматически подберутся под протокол',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withOpacity(0.55),
                    ),
                  ),
                ),
                if (_manualPorts) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _corePort,
                          enabled: !_deploying,
                          keyboardType: TextInputType.number,
                          decoration: _inputDecoration('Core'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _warpPort,
                          enabled: !_deploying,
                          keyboardType: TextInputType.number,
                          decoration: _inputDecoration('WARP'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _listenPort,
                          enabled: !_deploying,
                          keyboardType: TextInputType.number,
                          decoration: _inputDecoration('Listen'),
                        ),
                      ),
                    ],
                  ),
                ],
              ]),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _deploying ? null : _startDeploy,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF7E84E),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(_deploying ? 'Деплой...' : 'Задеплоить'),
                ),
              ),
              const SizedBox(height: 14),

              _block('Журнал', [
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 90),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(10),
                    border:
                        Border.all(color: Colors.white.withOpacity(0.12)),
                  ),
                  child: SelectableText(
                    _log.isEmpty ? 'Ожидание...' : _log,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
        isDense: true,
        filled: true,
        fillColor: Colors.white.withOpacity(0.06),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.15)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.15)),
        ),
      );

  Widget _modeChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFF7E84E).withOpacity(0.18)
              : Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? const Color(0xFFF7E84E).withOpacity(0.75)
                : Colors.white.withOpacity(0.15),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? const Color(0xFFF7E84E) : Colors.white70,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _block(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.7,
                fontWeight: FontWeight.w700,
                color: Colors.white.withOpacity(0.4),
              ),
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}