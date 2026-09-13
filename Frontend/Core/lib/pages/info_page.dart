import 'package:flutter/material.dart';

import '../api.dart';
import '../widgets/glass_card.dart';

class InfoPage extends StatefulWidget {
  const InfoPage({super.key});

  @override
  State<InfoPage> createState() => _InfoPageState();
}

class _InfoPageState extends State<InfoPage> {
  // -------- ядро CSQTT --------
  String _coreRemoteVersion = '—';
  bool _coreHasUpdate = false;
  bool _checkingCore = false;

  // -------- LaLune --------
  static const String _laluneVersion = '0.5.0';
  String _laluneRemoteVersion = '—';
  bool _laluneHasUpdate = false;
  bool _checkingLaLune = false;

  bool _updateDialogShown = false;

  @override
  void initState() {
    super.initState();
    // Запускаем фоновую проверку — мост сам обновит кэш.
    _kickCoreCheck();
    _kickLaLuneCheck();
    _startPolling();
  }

  void _kickCoreCheck() {
    // Синхронно читаем кэш, одновременно триггерим обновление.
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

  /// Периодически перечитывает кэш (мост обновляет его в фоне).
  void _startPolling() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return false;

      final core = Api.checkCoreUpdate();
      final lalune = Api.checkLaLuneUpdate();

      if (core.version != _coreRemoteVersion ||
          core.hasUpdate != _coreHasUpdate) {
        _applyCoreInfo(core);
      }
      if (lalune.version != _laluneRemoteVersion ||
          lalune.hasUpdate != _laluneHasUpdate) {
        _applyLaLuneInfo(lalune);
      }
      return true;
    });
  }

  Future<void> _manualCheckCore() async {
    setState(() => _checkingCore = true);
    _kickCoreCheck();
    // Дадим мосту секунду на обновление кэша
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

  // ============================================================
  //  Модалка предложения обновиться
  // ============================================================

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

              // --------- Ядро CSQTT ---------
              _block('Ядро CSQTT', [
                _kv('Доступная версия', _coreRemoteVersion),
                _kv('CSQTT (kernel)', '2.1.9'),
              ]),
              _actionButton(
                label: _checkingCore
                    ? 'Проверка...'
                    : 'Проверить обновления ядра',
                onTap: _checkingCore ? null : _manualCheckCore,
              ),
              if (_coreHasUpdate) ...[
                const SizedBox(height: 8),
                _updateHint(
                  'Доступно обновление ядра: $_coreRemoteVersion',
                  onTap: () => Api.updateCore(),
                ),
              ],
              const SizedBox(height: 18),

              // --------- LaLune ---------
              _block('LaLune', [
                _kv('Установлено', _laluneVersion),
                _kv('Доступно', _laluneRemoteVersion),
              ]),
              _actionButton(
                label: _checkingLaLune
                    ? 'Проверка...'
                    : 'Проверить обновления LaLune',
                onTap: _checkingLaLune ? null : _manualCheckLaLune,
              ),
              if (_laluneHasUpdate) ...[
                const SizedBox(height: 8),
                _updateHint(
                  'Доступно обновление LaLune: $_laluneRemoteVersion',
                  onTap: () => Api.openLaLuneReleases(),
                ),
              ],
              const SizedBox(height: 18),

              // --------- Авторы ---------
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

  Widget _updateHint(String text, {required VoidCallback onTap}) {
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
