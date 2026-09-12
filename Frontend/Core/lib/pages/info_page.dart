import 'dart:convert';
import 'package:flutter/material.dart';

import '../api.dart';
import '../widgets/glass_card.dart';

class InfoPage extends StatefulWidget {
  const InfoPage({super.key});

  @override
  State<InfoPage> createState() => _InfoPageState();
}

class _InfoPageState extends State<InfoPage> {
  String _remoteVersion = '—';
  String _laluneLocal = '0.5.0';
  String _laluneRemote = '—';
  bool _checking = false;

  Future<void> _checkCore() async {
    setState(() => _checking = true);
    final raw = Api.checkUpdate();
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      setState(() {
        _remoteVersion = (j['version'] ?? '—').toString();
      });
    } catch (_) {}
    setState(() => _checking = false);
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
              const Text('🌙 LaLune',
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFF7E84E))),
              const SizedBox(height: 4),
              Text('Client v0.5.0',
                  style: TextStyle(color: Colors.white.withOpacity(0.5))),
              const SizedBox(height: 20),
              _block('Ядро CSQTT', [
                _kv('Доступная версия', _remoteVersion),
                _kv('CSQTT (kernel)', '2.1.9'),
              ]),
              _actionButton(
                label: _checking
                    ? 'Проверка...'
                    : 'Проверить обновления ядра',
                onTap: _checking ? null : _checkCore,
              ),
              const SizedBox(height: 18),
              _block('LaLune', [
                _kv('Установлено', _laluneLocal),
                _kv('Доступно', _laluneRemote),
              ]),
              _actionButton(label: 'Проверка обновлений LaLune', onTap: () {}),
              const SizedBox(height: 18),
              _block('Авторы', [
                _kv('CSQTT', 'amurcanov'),
                _kv('LaLune', '@Endlad7373'),
              ]),
            ],
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
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(k,
                style: TextStyle(color: Colors.white.withOpacity(0.65))),
          ),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _actionButton({required String label, VoidCallback? onTap}) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: BorderSide(color: Colors.white.withOpacity(0.2)),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Text(label),
      ),
    );
  }
}
