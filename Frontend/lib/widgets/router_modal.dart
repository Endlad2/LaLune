// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Модалка «Подключить OpenWRT».
//
// Сверху — заголовок, кнопка «Сканировать» / индикатор «Ищем роутеры...».
// Список найденных + сохранённых роутеров. Клик по роутеру — вернуть его
// из модалки.
// Снизу — кнопка «Ввести IP роутера вручную».

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/router_info.dart';
import '../state/router_notifier.dart';

Future<RouterInfo?> showRouterModal(BuildContext context) {
  return showDialog<RouterInfo>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.65),
    builder: (_) => const _RouterModal(),
  );
}

class _RouterModal extends ConsumerStatefulWidget {
  const _RouterModal();

  @override
  ConsumerState<_RouterModal> createState() => _RouterModalState();
}

class _RouterModalState extends ConsumerState<_RouterModal> {
  final _ipCtl = TextEditingController();
  bool _showManual = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(routerProvider.notifier).startScan();
    });
  }

  @override
  void dispose() {
    _ipCtl.dispose();
    super.dispose();
  }

  Future<void> _submitManual() async {
    final ip = _ipCtl.text.trim();
    if (ip.isEmpty) return;
    final info = await ref.read(routerProvider.notifier).addManualIp(ip);
    if (!mounted) return;
    if (info != null) {
      Navigator.pop(context, info);
    } else {
      final err = ref.read(routerProvider).error ?? 'Не удалось добавить';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err),
          backgroundColor: Colors.red.shade800,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(routerProvider);

    // Объединяем: сохранённые + найденные, без дублей.
    final map = <String, RouterInfo>{};
    for (final r in st.savedRouters) {
      map[r.ip] = r;
    }
    for (final r in st.scannedRouters) {
      map[r.ip] = r;
    }
    final list = map.values.toList()
      ..sort((a, b) => a.ip.compareTo(b.ip));

    return Dialog(
      backgroundColor: const Color(0xFF0F1540),
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withOpacity(0.12)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Подключить OpenWRT',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (st.scanning)
                Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Ищем роутеры...',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.white.withOpacity(0.7),
                      ),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    Icon(
                      Icons.check_circle_outline,
                      size: 14,
                      color: Colors.white.withOpacity(0.5),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Найдено: ${list.length}',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.white.withOpacity(0.7),
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () =>
                          ref.read(routerProvider.notifier).startScan(),
                      child: const Text('Сканировать снова'),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              Expanded(
                child: list.isEmpty
                    ? Center(
                        child: Text(
                          st.scanning
                              ? 'Пожалуйста, подождите...'
                              : 'Роутеры не найдены',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 6),
                        itemBuilder: (_, i) =>
                            _RouterTile(router: list[i]),
                      ),
              ),
              const SizedBox(height: 8),
              if (!_showManual)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => setState(() => _showManual = true),
                    icon: const Icon(Icons.edit, size: 16),
                    label: const Text('Ввести IP роутера вручную'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side:
                          BorderSide(color: Colors.white.withOpacity(0.2)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                )
              else ...[
                TextField(
                  controller: _ipCtl,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(
                    hintText: '192.168.1.1',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _submitManual(),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () =>
                            setState(() => _showManual = false),
                        child: const Text('Отмена'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _submitManual,
                        child: const Text('Добавить'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RouterTile extends ConsumerWidget {
  final RouterInfo router;
  const _RouterTile({required this.router});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(routerProvider).activeRouter?.ip == router.ip;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => Navigator.pop(context, router),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFF4A6CF7).withOpacity(0.18)
              : Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active
                ? const Color(0xFF4A6CF7).withOpacity(0.55)
                : Colors.white.withOpacity(0.08),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.router, size: 18, color: Colors.white70),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    router.displayName,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${router.ip}:1062'
                    '${router.platform.isNotEmpty ? " · ${router.platform}" : ""}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Colors.white.withOpacity(0.55),
                    ),
                  ),
                ],
              ),
            ),
            if (active)
              const Icon(
                Icons.check_circle,
                size: 16,
                color: Color(0xFF7CFF9A),
              ),
          ],
        ),
      ),
    );
  }
}
