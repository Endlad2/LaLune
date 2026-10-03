// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/core_info.dart';
import '../models/update_info.dart';
import '../state/providers.dart';
import '../theme/assets.dart';
import '../widgets/glass_card.dart';

class InfoPage extends ConsumerStatefulWidget {
  const InfoPage({super.key});

  @override
  ConsumerState<InfoPage> createState() => _InfoPageState();
}

class _InfoPageState extends ConsumerState<InfoPage> {
  static const String _laluneVersion = '0.6.0';

  CoreInfo _core = CoreInfo.empty;
  UpdateInfo _lalune = UpdateInfo.empty;
  bool _checkingCore = false;
  bool _updatingCore = false;
  bool _checkingLaLune = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_refreshAll);
  }

  Future<void> _refreshAll() async {
    final api = ref.read(apiClientProvider);

    // Core
    try {
      final j = await api.getJson('/core/check');
      if (mounted) setState(() => _core = CoreInfo.fromJson(j));
    } catch (_) {}

    // LaLune
    try {
      final j = await api.getJson('/update/check');
      if (mounted) setState(() => _lalune = UpdateInfo.fromJson(j));
    } catch (_) {}
  }

  Future<void> _manualCheckCore() async {
    setState(() => _checkingCore = true);
    await _refreshAll();
    if (mounted) setState(() => _checkingCore = false);
  }

  Future<void> _manualCheckLaLune() async {
    setState(() => _checkingLaLune = true);
    await _refreshAll();
    if (mounted) setState(() => _checkingLaLune = false);
  }

  Future<void> _startCoreUpdate() async {
    if (_updatingCore) return;
    setState(() => _updatingCore = true);
    _toast('Обновляю ядро...');
    final api = ref.read(apiClientProvider);
    try {
      await api.postJson('/core/download/sync', {});
      _toast('Ядро обновлено');
      await _refreshAll();
    } catch (e) {
      _toast('Не удалось обновить ядро: $e');
    }
    if (mounted) setState(() => _updatingCore = false);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
      backgroundColor: Colors.black.withOpacity(0.85),
    ));
  }

  // ============================================================
  //  QR-модалка
  // ============================================================

  Future<void> _showMaxQrDialog() async {
    final screenWidth = MediaQuery.of(context).size.width;
    final qrSize = math.min(screenWidth - 80, 420.0);

    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.65),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF0F1540),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Канал LaLune в MAX',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(
                  Assets.maxQr,
                  width: qrSize,
                  height: qrSize,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Container(
                    width: qrSize,
                    height: qrSize,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: Colors.white.withOpacity(0.15)),
                    ),
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.qr_code_2,
                              size: 64, color: Colors.white54),
                          SizedBox(height: 8),
                          Text('assets/max_qr.jpg',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.white38)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Отсканируйте QR-код, чтобы подписаться на канал',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12.5,
                    color: Colors.white.withOpacity(0.65)),
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
              Text('Client v$_laluneVersion',
                  style: TextStyle(color: Colors.white.withOpacity(0.5))),
              const SizedBox(height: 20),

              // Ядро
              _block('Ядро CSQTT', [
                _kv('Установлено', _core.localVersion.isEmpty
                    ? '—' : _core.localVersion),
                _kv('Доступно', _core.remoteVersion.isEmpty
                    ? '—' : _core.remoteVersion),
              ]),
              _actionButton(
                label: _checkingCore
                    ? 'Проверка...'
                    : 'Проверить обновления ядра',
                onTap: _checkingCore ? null : _manualCheckCore,
              ),
              if (_core.hasUpdate) ...[
                const SizedBox(height: 8),
                _updateHint(
                  _updatingCore
                      ? 'Обновление...'
                      : 'Обновить ядро до ${_core.remoteVersion}',
                  onTap: _updatingCore ? null : _startCoreUpdate,
                ),
              ],
              const SizedBox(height: 18),

              // LaLune
              _block('LaLune', [
                _kv('Установлено', _laluneVersion),
                _kv('Доступно', _lalune.remoteTag.isEmpty
                    ? '—' : _lalune.remoteTag),
              ]),
              _actionButton(
                label: _checkingLaLune
                    ? 'Проверка...'
                    : 'Проверить обновления LaLune',
                onTap: _checkingLaLune ? null : _manualCheckLaLune,
              ),
              if (_lalune.hasUpdate) ...[
                const SizedBox(height: 8),
                _updateHint(
                  'Доступно обновление LaLune: ${_lalune.remoteTag}',
                  onTap: () {
                    final api = ref.read(apiClientProvider);
                    api.getJson('/update/url').then((j) {
                      final url = j['url'] as String? ?? '';
                      if (url.isNotEmpty) {
                        api.postJson('/platform/open-url', {'url': url});
                      }
                    });
                  },
                ),
              ],
              const SizedBox(height: 18),

              _block('Авторы', [
                _kv('CSQTT', 'amurcanov'),
                _kv('LaLune', '@Endlad7373'),
              ]),
              const SizedBox(height: 18),

              _block('Ограничения интернета', [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    'Если вы находитесь в белых списках или подобных '
                    'ограничениях интернета, при которых недоступен сайт '
                    'GitHub, а вам надо обновиться — используйте наш канал '
                    'в MAX. Туда выходят все апдейты.',
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: Colors.white.withOpacity(0.75)),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _showMaxQrDialog,
                    icon: const Icon(Icons.qr_code_2, size: 16),
                    label: const Text('Показать QR для канала MAX'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(color: Colors.white.withOpacity(0.2)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
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

  Widget _block(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title.toUpperCase(),
                style: TextStyle(
                    fontSize: 10.5,
                    letterSpacing: 0.7,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withOpacity(0.4))),
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
              borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(label),
      ),
    );
  }

  Widget _updateHint(String text, {VoidCallback? onTap}) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFF7E84E),
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(text, textAlign: TextAlign.center),
      ),
    );
  }
}
