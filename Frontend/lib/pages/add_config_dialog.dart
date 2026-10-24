// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Диалог добавления конфига. Протокол выбирается из списка.
// Placeholder для ссылки зависит от протокола и НЕ содержит реальных данных.

import 'package:flutter/material.dart';

import '../widgets/toast.dart';

class AddConfigResult {
  final String protocol;
  final String link;
  const AddConfigResult(this.protocol, this.link);
}

const _protocols = <String>['CSQTT 2.1.9', 'CSQTT 2.5.1', 'PaperFlux'];

String _placeholderFor(String protocol) {
  switch (protocol) {
    case 'PaperFlux':
      return 'paperflux://config?v=1&id=...&name=...&server=...&ip=...'
          '&transport=...&doc=...&token=...&volga=...';
    case 'CSQTT 2.1.9':
    case 'CSQTT 2.5.1':
    case 'CSQTT':
    default:
      return 'csqtt://connect?v=2&host=...&peer=...&password=...&hashes=h1+h2';
  }
}

Future<AddConfigResult?> showAddConfigDialog(BuildContext context) async {
  final linkCtrl = TextEditingController();
  String protocol = 'CSQTT 2.1.9';

  final result = await showDialog<AddConfigResult>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.55),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          final placeholder = _placeholderFor(protocol);

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
                    const Text('Протокол',
                        style: TextStyle(fontSize: 12, color: Colors.white70)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      value: protocol,
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
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(p),
                              if (isRisky) ...[
                                const SizedBox(width: 8),
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => Toast.show(
                                    ctx,
                                    'CSQTT 2.5.1: возможны проблемы с DTLS, совместимостью соединения и стабильностью туннеля. Если подключение не работает, попробуйте CSQTT 2.1.9.',
                                    duration: const Duration(seconds: 5),
                                  ),
                                  child: Container(
                                    width: 20,
                                    height: 20,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFFB347),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    child: const Text(
                                      '!',
                                      style: TextStyle(
                                        color: Color(0xFF302900),
                                        fontWeight: FontWeight.w900,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        setLocal(() => protocol = v);
                      },
                    ),
                    const SizedBox(height: 14),
                    const Text('Ссылка',
                        style: TextStyle(fontSize: 12, color: Colors.white70)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: linkCtrl,
                      autofocus: true,
                      maxLines: 4,
                      minLines: 2,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: placeholder,
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
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Отмена'),
              ),
              ElevatedButton(
                onPressed: () {
                  final link = linkCtrl.text.trim();
                  if (link.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Введите ссылку')),
                    );
                    return;
                  }
                  Navigator.pop(ctx, AddConfigResult(protocol, link));
                },
                child: const Text('Сохранить'),
              ),
            ],
          );
        },
      );
    },
  );

  linkCtrl.dispose();
  return result;
}
