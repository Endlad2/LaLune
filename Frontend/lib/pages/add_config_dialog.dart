// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';

class AddConfigResult {
  final String protocol;
  final String link;
  const AddConfigResult(this.protocol, this.link);
}

const _protocols = <String>['CSQTT', 'PaperFlux', 'FreeTurn'];

String _placeholderFor(String protocol) {
  switch (protocol) {
    case 'PaperFlux':
      return 'paperflux://config?v=1&id=...&name=...&server=...&ip=...';
    case 'FreeTurn':
      return 'freeturn://<base64url(json)>';
    case 'CSQTT':
    default:
      return 'csqtt://connect?v=2&host=...&peer=...&password=...';
  }
}

Future<AddConfigResult?> showAddConfigDialog(BuildContext context) async {
  final linkCtrl = TextEditingController();
  String protocol = 'CSQTT';

  final result = await showDialog<AddConfigResult>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.55),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          final placeholder = _placeholderFor(protocol);

          return AlertDialog(
            backgroundColor: const Color(0xFF0F1540),
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
                      dropdownColor: const Color(0xFF0F1540),
                      style: const TextStyle(fontSize: 13, color: Colors.white),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: _protocols
                          .map((p) =>
                              DropdownMenuItem(value: p, child: Text(p)))
                          .toList(),
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
