// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Диалог добавления конфига. Контроллер принадлежит State диалога,
// поэтому живёт столько же, сколько TextField, и корректно освобождается
// при закрытии через кнопку, системный Back или нажатие вне модалки.

import 'package:flutter/material.dart';

import '../widgets/toast.dart';

class AddConfigResult {
  final String protocol;
  final String link;
  const AddConfigResult(this.protocol, this.link);
}

const _protocols = <String>[
  'CSQTT 2.1.9',
  'CSQTT 2.5.1',
  'CSQTTR',
  'PaperFlux',
];

String _placeholderFor(String protocol) {
  switch (protocol) {
    case 'PaperFlux':
      return 'paperflux://config?v=1&id=...&name=...&server=...&ip=...'
          '&transport=...&doc=...&token=...&volga=...';
    default:
      return 'csqtt://connect?v=2&host=...&peer=...&password=...&hashes=h1+h2';
  }
}

Future<AddConfigResult?> showAddConfigDialog(BuildContext context) {
  return showDialog<AddConfigResult>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withOpacity(0.55),
    useRootNavigator: true,
    builder: (_) => const _AddConfigDialog(),
  );
}

class _AddConfigDialog extends StatefulWidget {
  const _AddConfigDialog();

  @override
  State<_AddConfigDialog> createState() => _AddConfigDialogState();
}

class _AddConfigDialogState extends State<_AddConfigDialog> {
  late final TextEditingController _linkController;
  String _protocol = 'CSQTT 2.1.9';

  @override
  void initState() {
    super.initState();
    _linkController = TextEditingController();
  }

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  void _save() {
    final link = _linkController.text.trim();
    if (link.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите ссылку')),
      );
      return;
    }
    Navigator.of(context, rootNavigator: true).pop(
      AddConfigResult(_protocol, link),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF21142B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withOpacity(0.1)),
      ),
      title: const Text('Добавить профиль'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Протокол',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: _protocol,
                isExpanded: true,
                dropdownColor: const Color(0xFF21142B),
                style: const TextStyle(fontSize: 13, color: Colors.white),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: _protocols.map((p) {
                  final isRisky = p == 'CSQTT 2.5.1';
                  return DropdownMenuItem<String>(
                    value: p,
                    child: Row(
                      children: [
                        Expanded(child: Text(p, overflow: TextOverflow.ellipsis)),
                        if (isRisky)
                          IconButton(
                            tooltip: 'Предупреждение о CSQTT 2.5.1',
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                            onPressed: () => Toast.show(
                              context,
                              'CSQTT 2.5.1: возможны проблемы с DTLS, совместимостью соединения и стабильностью туннеля. Если подключение не работает, попробуйте CSQTT 2.1.9.',
                              duration: const Duration(seconds: 5),
                            ),
                            icon: const Icon(
                              Icons.warning_amber_rounded,
                              color: Color(0xFFFFB347),
                              size: 19,
                            ),
                          ),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null && mounted) {
                    setState(() => _protocol = value);
                  }
                },
              ),
              const SizedBox(height: 14),
              const Text(
                'Ссылка',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _linkController,
                autofocus: true,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
                maxLines: 4,
                minLines: 2,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: _placeholderFor(_protocol),
                  hintStyle: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withOpacity(0.35),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
          child: const Text('Отмена'),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}
