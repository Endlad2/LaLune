// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/logs_notifier.dart';
import '../widgets/glass_card.dart';

class LogsPage extends ConsumerStatefulWidget {
  const LogsPage({super.key});

  @override
  ConsumerState<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends ConsumerState<LogsPage> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(logsProvider);

    // Прокрутка вниз при появлении новых строк.
    ref.listen(logsProvider, (prev, next) {
      if (prev?.lines.length != next.lines.length) _scrollToBottom();
    });

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Column(
            children: [
              Row(
                children: [
                  const Text('Логи',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                    onPressed: () => ref.read(logsProvider.notifier).clear(),
                    tooltip: 'Очистить',
                    icon: const Icon(Icons.delete_outline, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: GlassCard(
                  padding: EdgeInsets.zero,
                  child: Scrollbar(
                    controller: _scroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      child: logs.lines.isEmpty
                          ? Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 30),
                              child: Center(
                                child: Text('Логи пусты',
                                    style: TextStyle(
                                        color:
                                            Colors.white.withOpacity(0.45))),
                              ),
                            )
                          : SelectableText(
                              logs.lines.join('\n'),
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.45,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
