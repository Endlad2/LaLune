// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';

class AddConfigResult {
  final String protocol;
  final String link;
  const AddConfigResult(this.protocol, this.link);
}

Future<AddConfigResult?> showAddConfigDialog(BuildContext context) async {
  final csqttCtrl = TextEditingController();

  String protocol = 'CSQTT';

  String normalizeLink() {
    return csqttCtrl.text.trim();
  }

  bool isLinkValid() {
    return normalizeLink().isNotEmpty;
  }

  final result = await showDialog<AddConfigResult>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.55),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            backgroundColor: const Color(0xFF0F1540),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.white.withOpacity(0.1)),
            ),
            title: const Text('Добавить профиль'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _protocolDropdown(protocol, (v) {
                      setLocal(() => protocol = v ?? 'CSQTT');
                    }),
                    const SizedBox(height: 14),
                    _linkField(
                        csqttCtrl,
                        'csqtt://connect?v=2&host=...&peer=...&password=...&hashes=...'),
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
                  if (!isLinkValid()) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Заполните все обязательные поля')),
                    );
                    return;
                  }
                  Navigator.pop(
                      ctx, AddConfigResult(protocol, normalizeLink()));
                },
                child: const Text('Сохранить'),
              ),
            ],
          );
        },
      );
    },
  );

  csqttCtrl.dispose();

  return result;
}

Widget _protocolDropdown(String value, ValueChanged<String?> onChanged) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Протокол',
          style: TextStyle(fontSize: 12, color: Colors.white70)),
      const SizedBox(height: 6),
      DropdownButtonFormField<String>(
        value: value,
        dropdownColor: const Color(0xFF0F1540),
        style: const TextStyle(fontSize: 13, color: Colors.white),
        decoration:
            const InputDecoration(isDense: true, border: OutlineInputBorder()),
        items: const [
          DropdownMenuItem(value: 'CSQTT', child: Text('CSQTT')),
        ],
        onChanged: onChanged,
      ),
    ],
  );
}

Widget _linkField(TextEditingController controller, String hint) {
  return TextField(
    controller: controller,
    autofocus: true,
    maxLines: 3,
    minLines: 2,
    style: const TextStyle(fontSize: 13),
    decoration: InputDecoration(hintText: hint),
  );
}
