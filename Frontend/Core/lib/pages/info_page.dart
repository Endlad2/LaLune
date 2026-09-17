import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:flutter/material.dart';

import '../api.dart';
import '../widgets/glass_card.dart';

/// Возвращает true, если мы на Android или iOS.
bool _isMobilePlatform() {
  if (kIsWeb) return false;
  try {
    return Platform.isAndroid || Platform.isIOS;
  } catch (_) {
    return false;
  }
}

class InfoPage extends StatefulWidget {
  const InfoPage({super.key});

  @override
  State<InfoPage> createState() => _InfoPageState();
}

class _InfoPageState extends State<InfoPage> {
  String _coreRemoteVersion = '—';
  bool _coreHasUpdate = false;
  bool _checkingCore = false;
  bool _updatingCore = false;

  static const String _laluneVersion = '0.5.0';
  String _laluneRemoteVersion = '—';
  bool _laluneHasUpdate = false;
  bool _checkingLaLune = false;

  bool _updateDialogShown = false;
  bool _coreUpdateDialogShown = false;

  bool get _hideCoreBlock => _isMobilePlatform();

  @override
  void initState() {
    super.initState();
    _kickCoreCheck();
    _kickLaLuneCheck();
    _startPolling();
  }

  void _kickCoreCheck() {
    if (_hideCoreBlock) return;
    final info = Api.checkCoreUpdate();
    _applyCoreInfo(info);
  }

  void _kickLaLuneCheck() {
    final info = Api.checkLaLuneUpdate();
    _applyLaLuneInfo(info);
  }

  void _applyCoreInfo(UpdateInfo info) {
    if (!mounted) return;
    setState(() {
      _coreRemoteVersion = info.version.isEmpty ? '—' : info.version;
      _coreHasUpdate = info.hasUpdate;
    });

    if (info.hasUpdate && !_coreUpdateDialogShown && !_hideCoreBlock) {
      _coreUpdateDialogShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showCoreUpdateDialog(info.version);
      });
    }
  }

  void _applyLaLuneInfo(UpdateInfo info) {
    if (!mounted) return;
    setState(() {
      _laluneRemoteVersion = info.version.isEmpty ? '—' : info.version;
      _laluneHasUpdate = info.hasUpdate;
    });

    if (info.hasUpdate && !_updateDialogShown) {
      _updateDialogShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showLaLuneUpdateDialog(info.version);
      });
    }
  }

  void _startPolling() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return false;

      if (!_hideCoreBlock) {
        final core = Api.checkCoreUpdate();
        if (core.version != _coreRemoteVersion ||
            core.hasUpdate != _coreHasUpdate) {
          _applyCoreInfo(core);
        }
      }

      final lalune = Api.checkLaLuneUpdate();
      if (lalune.version != _laluneRemoteVersion ||
          lalune.hasUpdate != _laluneHasUpdate) {
        _applyLaLuneInfo(lalune);
      }
      return true;
    });
  }

  Future<void> _manualCheckCore() async {
    if (_hideCoreBlock) return;
    setState(() => _checkingCore = true);
    _kickCoreCheck();
    await Future.delayed(const Duration(seconds: 1));
    _kickCoreCheck();
    if (!mounted) return;
    setState(() => _checkingCore = false);
  }

  Future<void> _manualCheckLaLune() async {
    setState(() => _checkingLaLune = true);
    _kickLaLuneCheck();
    await Future.delayed(const Duration(seconds: 1));
    _kickLaLuneCheck();
    if (!mounted) return;
    setState(() => _checkingLaLune = false);
  }

  Future<void> _showCoreUpdateDialog(String version) async {
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F1540),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
        title: const Text('Доступно обновление ядра'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Новая версия: $version',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Обновление будет скачано автоматически.',
              style: TextStyle(color: Colors.white.withOpacity(0.7)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Позже'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Обновить'),
          ),
        ],
      ),
    );

    if (go == true) {
      _startCoreUpdate();
    }
  }

  Future<void> _showLaLuneUpdateDialog(String version) async {
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F1540),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
        title: const Text('Доступно обновление LaLune'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Новая версия: $version',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Установленная версия: $_laluneVersion',
              style: TextStyle(color: Colors.white.withOpacity(0.65)),
            ),
            const SizedBox(height: 14),
            Text(
              'Открыть страницу загрузки и скачать новую версию?',
              style: TextStyle(color: Colors.white.withOpacity(0.8)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Позже'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Открыть релиз'),
          ),
        ],
      ),
    );

    if (go == true) {
      Api.openLaLuneReleases();
    }
  }

  Future<void> _startCoreUpdate() async {
    if (_updatingCore) return;
    setState(() => _updatingCore = true);

    _showToast('Обновляю ядро...');

    final ok = Api.updateCoreAndWait();

    if (!mounted) return;
    setState(() => _updatingCore = false);

    if (ok) {
      _showToast('Ядро обновлено. Проверьте версию.');
      _kickCoreCheck();
    } else {
      _showToast('Не удалось обновить ядро. Смотрите логи.');
    }
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

  // ============================================================
  //  QR-модалка для канала MAX — адаптивный размер
  // ============================================================

  Future<void> _showMaxQrDialog() async {
    // Адаптивный размер: минимум из (ширина экрана - 80) и 420.
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
                    child: Text(
                      'Канал LaLune в MAX',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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
                  'assets/max_qr.jpg',
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
                        color: Colors.white.withOpacity(0.15),
                      ),
                    ),
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.qr_code_2, size: 64, color: Colors.white54),
                          SizedBox(height: 8),
                          Text(
                            'assets/max_qr.jpg',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white38,
                            ),
                          ),
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
                  color: Colors.white.withOpacity(0.65),
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

              if (!_hideCoreBlock) ...[
                _block('Ядро CSQTT', [
                  _kv('Доступная версия', _coreRemoteVersion),
                  _kv('CSQTT (kernel)', '2.1.9'),
                ]),
                _actionButton(
                  label: _checkingCore
                      ? 'Проверка...'
                      : 'Проверить обновления ядра',
                  onTap: _checkingCore ? null : () => _manualCheckCore(),
                ),
                if (_coreHasUpdate) ...[
                  const SizedBox(height: 8),
                  _updateHint(
                    _updatingCore
                        ? 'Обновление...'
                        : 'Обновить ядро до $_coreRemoteVersion',
                    onTap: _updatingCore ? null : () => _startCoreUpdate(),
                  ),
                ],
                const SizedBox(height: 18),
              ],

              _block('LaLune', [
                _kv('Установлено', _laluneVersion),
                _kv('Доступно', _laluneRemoteVersion),
              ]),
              _actionButton(
                label: _checkingLaLune
                    ? 'Проверка...'
                    : 'Проверить обновления LaLune',
                onTap: _checkingLaLune ? null : () => _manualCheckLaLune(),
              ),
              if (_laluneHasUpdate) ...[
                const SizedBox(height: 8),
                _updateHint(
                  'Доступно обновление LaLune: $_laluneRemoteVersion',
                  onTap: () => Api.openLaLuneReleases(),
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
                    'Если вы находитесь в белых списках или подобных ограничениях '
                    'интернета, при которых недоступен сайт GitHub, а вам надо '
                    'обновиться — используйте наш канал в MAX. Туда выходят все апдейты.',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: Colors.white.withOpacity(0.75),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _showMaxQrDialog(),
                    icon: const Icon(Icons.qr_code_2, size: 16),
                    label: const Text('Показать QR для канала MAX'),
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
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Text(text, textAlign: TextAlign.center),
      ),
    );
  }
}
