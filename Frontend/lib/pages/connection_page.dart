// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/config_item.dart';
import '../state/configs_notifier.dart';
import '../state/vpn_notifier.dart';
import '../widgets/config_selector.dart';
import '../widgets/moon_button.dart';
import '../widgets/toast.dart';
import 'add_config_dialog.dart';

class ConnectionPage extends ConsumerStatefulWidget {
  final VoidCallback? onReload;
  const ConnectionPage({super.key, this.onReload});

  @override
  ConsumerState<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends ConsumerState<ConnectionPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(configsProvider.notifier).reload());
  }

  Future<void> _toggle() async {
    final vpn = ref.read(vpnProvider);
    if (vpn.state == 'disconnecting') return;
    if (vpn.connected ||
        vpn.state == 'connecting' ||
        vpn.state == 'checking') {
      final ok = await ref.read(vpnProvider.notifier).disconnect();
      if (!mounted) return;
      Toast.show(
        context,
        ok ? 'Отключено' : 'Не удалось отключиться',
        isError: !ok,
      );
      return;
    }
    final sel = ref.read(configsProvider).selected;
    if (sel == null) {
      Toast.show(context, 'Выберите конфиг', isError: true);
      return;
    }
    final ok = await ref.read(vpnProvider.notifier).connect(sel.id);
    if (!mounted) return;
    if (ok) {
      Toast.show(context, 'Подключение...');
    } else {
      final message = ref.read(vpnProvider).message;
      Toast.show(
        context,
        message.isNotEmpty && message != 'Ошибка подключения'
            ? message
            : 'Ошибка подключения',
        isError: true,
      );
    }
  }

  Future<void> _showAddDialog() async {
    final result = await showAddConfigDialog(context);
    if (result == null) return;
    if (result.link.isEmpty) {
      if (!mounted) return;
      Toast.show(context, 'Введите ссылку', isError: true);
      return;
    }
    final ok = await ref
        .read(configsProvider.notifier)
        .add(result.link, result.protocol);
    if (!mounted) return;
    if (ok) {
      Toast.show(context, 'Профиль сохранён');
      widget.onReload?.call();
    } else {
      final error = ref.read(configsProvider).error;
      Toast.show(
        context,
        error == null || error.trim().isEmpty
            ? 'Не удалось сохранить профиль'
            : 'Не удалось сохранить: $error',
        isError: true,
        duration: const Duration(seconds: 7),
      );
    }
  }

  Future<void> _confirmDelete(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F1540),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
        title: const Text('Удалить конфиг?'),
        content: const Text('Это действие нельзя отменить.',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final deleted = await ref.read(configsProvider.notifier).delete(id);
      if (!mounted) return;
      if (!deleted) {
        final error = ref.read(configsProvider).error;
        Toast.show(
          context,
          error == null || error.trim().isEmpty
              ? 'Не удалось удалить профиль'
              : 'Не удалось удалить: $error',
          isError: true,
          duration: const Duration(seconds: 7),
        );
        return;
      }
      widget.onReload?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final configsState = ref.watch(configsProvider);
    final vpn = ref.watch(vpnProvider);
    final tunChecking = vpn.state == 'checking' && vpn.message == 'Проверка TUN';
    final visuallyConnected = vpn.connected || tunChecking;

    return Stack(
      children: [
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MoonButton(connected: visuallyConnected, onTap: _toggle),
                const SizedBox(height: 20),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  child: Column(
                    key: ValueKey('${vpn.state}:${vpn.message}'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (!tunChecking &&
                              (vpn.state == 'connecting' ||
                                  vpn.state == 'checking' ||
                                  vpn.state == 'disconnecting')) ...[
                            SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  vpn.state == 'disconnecting'
                                      ? Colors.white70
                                      : const Color(0xFFF7E84E),
                                ),
                              ),
                            ),
                            const SizedBox(width: 9),
                          ],
                          Text(
                            visuallyConnected
                                ? 'Подключено'
                                : (vpn.state == 'checking'
                                    ? 'Проверка...'
                                    : (vpn.state == 'connecting'
                                            ? 'Подключение'
                                            : (vpn.state == 'disconnecting'
                                                ? 'Отключение...'
                                                : 'Отключено'))),
                            style: TextStyle(
                              fontSize: 16,
                              color: visuallyConnected
                                  ? const Color(0xFF7CFF9A)
                                  : Colors.white.withOpacity(0.6),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      if (tunChecking) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Проверка TUN',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white.withOpacity(0.5),
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                ConfigSelector(
                  configs: configsState.items,
                  selectedId: configsState.selectedId,
                  onSelect: (cfg) =>
                      ref.read(configsProvider.notifier).select(cfg.id),
                  onDelete: _confirmDelete,
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 12,
          right: 16,
          child: _AddButton(onTap: _showAddDialog),
        ),
      ],
    );
  }
}

class _AddButton extends StatefulWidget {
  final VoidCallback onTap;
  const _AddButton({required this.onTap});

  @override
  State<_AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<_AddButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _hover ? 0.92 : 1.0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(_hover ? 0.16 : 0.08),
              border: Border.all(
                color: Colors.white.withOpacity(_hover ? 0.28 : 0.14),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF4A6CF7)
                      .withOpacity(_hover ? 0.35 : 0.0),
                  blurRadius: 18,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(Icons.add, size: 24, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
