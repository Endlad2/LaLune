// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    final stats = _LogStats.fromLines(logs.lines);

    ref.listen(logsProvider, (prev, next) {
      final previousLast =
          prev != null && prev.lines.isNotEmpty ? prev.lines.last : null;
      final nextLast = next.lines.isNotEmpty ? next.lines.last : null;
      if (prev?.lines.length != next.lines.length ||
          previousLast != nextLast) {
        _scrollToBottom();
      }
    });

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            children: [
              Row(
                children: [
                  const Text('Логи',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Wrap(
                      spacing: 7,
                      runSpacing: 6,
                      children: [
                        _StatChip(
                            label: 'Инфо',
                            count: stats.info,
                            color: const Color(0xFF65B8F3)),
                        _StatChip(
                            label: 'Предупреждения',
                            count: stats.warnings,
                            color: const Color(0xFFFFB74D)),
                        _StatChip(
                            label: 'Ошибки',
                            count: stats.errors,
                            color: const Color(0xFFFF626C)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: logs.lines.isEmpty
                        ? null
                        : () async {
                            await Clipboard.setData(ClipboardData(
                                text: logs.lines.join('\n')));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Логи скопированы'),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            }
                          },
                    tooltip: 'Копировать все логи',
                    icon: const Icon(Icons.copy_all_outlined, size: 20),
                  ),
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
                  child: Column(
                    children: [
                      // Сводка закреплена над прокручиваемыми строками и всегда видна.
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.035),
                          border: Border(
                            bottom: BorderSide(
                                color: Colors.white.withOpacity(0.10)),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.analytics_outlined,
                                size: 16,
                                color: Colors.white.withOpacity(0.65)),
                            const SizedBox(width: 8),
                            Text(
                              'Статистика логов',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.white.withOpacity(0.8),
                              ),
                            ),
                            const Spacer(),
                            _CompactStat(label: 'INFO', count: stats.info,
                                color: const Color(0xFF65B8F3)),
                            const SizedBox(width: 10),
                            _CompactStat(label: 'WARN', count: stats.warnings,
                                color: const Color(0xFFFFB74D)),
                            const SizedBox(width: 10),
                            _CompactStat(label: 'ERROR', count: stats.errors,
                                color: const Color(0xFFFF626C)),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Scrollbar(
                          controller: _scroll,
                          child: logs.lines.isEmpty
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 30),
                                    child: Text('Логи пусты',
                                        style: TextStyle(
                                            color: Colors.white
                                                .withOpacity(0.45))),
                                  ),
                                )
                              : SelectionArea(
                                  child: ListView.builder(
                                    controller: _scroll,
                                    padding: const EdgeInsets.all(12),
                                    itemCount: logs.lines.length,
                                    itemBuilder: (context, index) => Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 7),
                                      child: _LogLine(line: logs.lines[index]),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ],
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

class _LogLine extends StatelessWidget {
  final String line;
  const _LogLine({required this.line});

  @override
  Widget build(BuildContext context) {
    final parsed = _ParsedLogLine.parse(line);
    return Wrap(
      spacing: 5,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final tag in parsed.tags) _TagPill(tag: tag),
        if (parsed.message.isNotEmpty)
          SelectableText(
            parsed.message,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              height: 1.45,
              color: Colors.white.withOpacity(0.88),
            ),
          ),
      ],
    );
  }
}

class _ParsedLogLine {
  final List<String> tags;
  final String message;
  const _ParsedLogLine(this.tags, this.message);

  static _ParsedLogLine parse(String line) {
    final prefix = RegExp(r'^\s*((?:\[[^\]]+\]\s*)+)').firstMatch(line);
    if (prefix == null) return _ParsedLogLine(const [], line);
    final tags = RegExp(r'\[([^\]]+)\]')
        .allMatches(prefix.group(1)!)
        .map((match) => match.group(1)!.trim())
        .where((tag) => tag.isNotEmpty)
        .toList();
    return _ParsedLogLine(tags, line.substring(prefix.end).trimLeft());
  }
}

enum _LogSeverity { info, warning, error, success, neutral }

_LogSeverity _severityForTag(String tag) {
  final value = tag.toUpperCase();
  if (value.contains('ERROR') ||
      value.contains('FAIL') ||
      value.contains('FATAL') ||
      value.contains('EXCEPTION') ||
      value == 'ERR') {
    return _LogSeverity.error;
  }
  if (value.contains('WARN')) return _LogSeverity.warning;
  if (value == 'OK' || value.contains('SUCCESS') || value == 'DONE') {
    return _LogSeverity.success;
  }
  if (value == 'INFO' || value == 'DEBUG' || value == 'TRACE') {
    return _LogSeverity.info;
  }
  return _LogSeverity.neutral;
}

Color _tagColor(String tag) {
  switch (_severityForTag(tag)) {
    case _LogSeverity.error:
      return const Color(0xFFFF626C);
    case _LogSeverity.warning:
      return const Color(0xFFFFB74D);
    case _LogSeverity.success:
      return const Color(0xFF65D6A2);
    case _LogSeverity.info:
      return const Color(0xFF65B8F3);
    case _LogSeverity.neutral:
      switch (tag.toUpperCase()) {
        case 'CORE':
          return const Color(0xFF63D3D1);
        case 'LUA':
          return const Color(0xFFC49BFF);
        case 'SMART-TUNNEL':
          return const Color(0xFF8FAEFF);
        case 'PAPERFLUX':
          return const Color(0xFFFFA86B);
        case 'CSQTT':
          return const Color(0xFF80CBC4);
        default:
          return const Color(0xFFB0BEC5);
      }
  }
}

class _TagPill extends StatelessWidget {
  final String tag;
  const _TagPill({required this.tag});

  @override
  Widget build(BuildContext context) {
    final color = _tagColor(tag);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.48), width: 0.8),
      ),
      child: Text(
        tag,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 10,
          height: 1.2,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _LogStats {
  final int info;
  final int warnings;
  final int errors;

  const _LogStats(
      {required this.info, required this.warnings, required this.errors});

  factory _LogStats.fromLines(List<String> lines) {
    var info = 0;
    var warnings = 0;
    var errors = 0;
    for (final line in lines) {
      final tags = _ParsedLogLine.parse(line).tags;
      final severities = tags.map(_severityForTag).toList();
      if (severities.contains(_LogSeverity.error)) {
        errors++;
      } else if (severities.contains(_LogSeverity.warning)) {
        warnings++;
      } else {
        info++;
      }
    }
    return _LogStats(info: info, warnings: warnings, errors: errors);
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _StatChip(
      {required this.label, required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(0.32)),
      ),
      child: Text(
        '$label: $count',
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _CompactStat extends StatelessWidget {
  final String label;
  final int count;
  final Color color;

  const _CompactStat(
      {required this.label, required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    return Text('$label $count',
        style: TextStyle(
            color: color, fontSize: 10, fontWeight: FontWeight.w700));
  }
}
