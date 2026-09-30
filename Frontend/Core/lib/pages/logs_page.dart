import 'package:flutter/material.dart';

import '../api.dart';
import '../widgets/glass_card.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  final _scroll = ScrollController();
  List<String> _logs = [];

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll();
  }

  void _refresh() {
    final l = Api.getLogs();
    setState(() => _logs = l);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _poll() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return false;
      _refresh();
      return true;
    });
  }

  void _clear() {
    Api.clearLogs();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
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
                    onPressed: _clear,
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
                      child: _logs.isEmpty
                          ? Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 30),
                              child: Center(
                                child: Text('Логи пусты',
                                    style: TextStyle(
                                        color: Colors.white
                                            .withOpacity(0.45))),
                              ),
                            )
                          : SelectableText(
                              _logs.join('\n'),
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
