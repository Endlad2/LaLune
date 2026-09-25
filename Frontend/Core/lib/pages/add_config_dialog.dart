import 'package:flutter/material.dart';

/// Result returned by [showAddConfigDialog] — the protocol plus the
/// canonical link string that will be passed to Api.saveConfig.
class AddConfigResult {
  final String protocol;
  final String link;
  const AddConfigResult(this.protocol, this.link);
}

/// Per-protocol "+" dialog.
///
/// PROJECT.md requirement:
///   - CSQTT   -> user enters a csqtt:// link
///   - OlcRTC  -> user enters an olcrtc:// link
///   - ToTS    -> user enters a tots:// link
///   - OpenFlux-> Tunnel name + Transport type, and (depending on the
///                transport) either Max Access Token + MAX Exit node user
///                id, or a Document URL.
Future<AddConfigResult?> showAddConfigDialog(BuildContext context) async {
  final csqttCtrl = TextEditingController();
  final olcrtcCtrl = TextEditingController();
  final totsCtrl = TextEditingController();
  final tunnelCtrl = TextEditingController();
  final maxTokenCtrl = TextEditingController();
  final maxExitCtrl = TextEditingController();
  final docUrlCtrl = TextEditingController();

  String protocol = 'CSQTT';
  String ofTransport = 'MAX'; // MAX | YandexDocs | MailDocs | OneME

  String normalizeLink() {
    switch (protocol) {
      case 'CSQTT':
        return csqttCtrl.text.trim();
      case 'FREETURN':
        return csqttCtrl.text.trim();
      case 'OLCRTC':
        return olcrtcCtrl.text.trim();
      case 'TOTS':
        return totsCtrl.text.trim();
      case 'OPENFLUX':
        final tunnel = tunnelCtrl.text.trim();
        final transport = ofTransport.toLowerCase();
        final buf = StringBuffer('openflux://' + transport);
        final params = <String>[];
        if (tunnel.isNotEmpty) {
          params.add('tunnel=' + Uri.encodeQueryComponent(tunnel));
        }
        if (ofTransport == 'MAX') {
          final tok = maxTokenCtrl.text.trim();
          final exit = maxExitCtrl.text.trim();
          if (tok.isNotEmpty) {
            params.add('token=' + Uri.encodeQueryComponent(tok));
          }
          if (exit.isNotEmpty) {
            params.add('exit=' + Uri.encodeQueryComponent(exit));
          }
        } else {
          final doc = docUrlCtrl.text.trim();
          if (doc.isNotEmpty) {
            params.add('doc=' + Uri.encodeQueryComponent(doc));
          }
        }
        if (params.isNotEmpty) {
          buf.write('?');
          buf.write(params.join('&'));
        }
        return buf.toString();
      default:
        return '';
    }
  }

  bool isLinkValid() {
    final link = normalizeLink();
    if (link.isEmpty) return false;
    if (protocol == 'OPENFLUX') {
      if (tunnelCtrl.text.trim().isEmpty) return false;
      if (ofTransport == 'MAX') {
        return maxTokenCtrl.text.trim().isNotEmpty;
      }
      return docUrlCtrl.text.trim().isNotEmpty;
    }
    return true;
  }

  final result = await showDialog<AddConfigResult>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.55),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          final children = <Widget>[];

          children.add(_protocolDropdown(protocol, (v) {
            setLocal(() => protocol = v ?? 'CSQTT');
          }));

          children.add(const SizedBox(height: 14));

          if (protocol == 'CSQTT' || protocol == 'FREETURN') {
            children.add(_linkField(
              csqttCtrl,
              'csqtt://connect?v=2&host=...&peer=...&password=...&hashes=...',
            ));
          } else if (protocol == 'OLCRTC') {
            children.add(_linkField(olcrtcCtrl, 'olcrtc://...'));
          } else if (protocol == 'TOTS') {
            children.add(_linkField(totsCtrl, 'tots://...'));
          } else if (protocol == 'OPENFLUX') {
            children.add(_labeledField(
              'Tunnel name',
              _oneLineField(tunnelCtrl, 'my-tunnel'),
            ));
            children.add(const SizedBox(height: 10));
            children.add(_labeledField(
              'Transport type',
              _transportDropdown(ofTransport, (v) {
                setLocal(() => ofTransport = v ?? 'MAX');
              }),
            ));
            children.add(const SizedBox(height: 10));
            if (ofTransport == 'MAX') {
              children.add(_labeledField(
                'Max Access Token',
                _oneLineField(maxTokenCtrl, 'access_token'),
              ));
              children.add(const SizedBox(height: 10));
              children.add(_labeledField(
                'MAX Exit node user id',
                _oneLineField(maxExitCtrl, '123456789'),
              ));
            } else {
              children.add(_labeledField(
                'Document URL',
                _oneLineField(
                  docUrlCtrl,
                  'https://cloud.mail.ru/public/uJ21/awAXVHpLw',
                ),
              ));
            }
          }

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
                  children: children,
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
                        content: Text('Заполните все обязательные поля'),
                      ),
                    );
                    return;
                  }
                  Navigator.pop(ctx, AddConfigResult(protocol, normalizeLink()));
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
  olcrtcCtrl.dispose();
  totsCtrl.dispose();
  tunnelCtrl.dispose();
  maxTokenCtrl.dispose();
  maxExitCtrl.dispose();
  docUrlCtrl.dispose();

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
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
        ),
        items: const [
          DropdownMenuItem(value: 'CSQTT', child: Text('CSQTT')),
          DropdownMenuItem(value: 'FREETURN', child: Text('FreeTurn')),
          DropdownMenuItem(value: 'OLCRTC', child: Text('OlcRTC')),
          DropdownMenuItem(value: 'OPENFLUX', child: Text('OpenFlux')),
          DropdownMenuItem(value: 'TOTS', child: Text('ToTS')),
        ],
        onChanged: onChanged,
      ),
    ],
  );
}

Widget _transportDropdown(String value, ValueChanged<String?> onChanged) {
  return DropdownButtonFormField<String>(
    value: value,
    dropdownColor: const Color(0xFF0F1540),
    style: const TextStyle(fontSize: 13, color: Colors.white),
    decoration: const InputDecoration(
      isDense: true,
      border: OutlineInputBorder(),
    ),
    items: const [
      DropdownMenuItem(value: 'MAX', child: Text('MAX')),
      DropdownMenuItem(value: 'YandexDocs', child: Text('Yandex Docs')),
      DropdownMenuItem(value: 'MailDocs', child: Text('Mail Docs')),
      DropdownMenuItem(value: 'OneME', child: Text('OneME')),
    ],
    onChanged: onChanged,
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

Widget _oneLineField(TextEditingController controller, String hint) {
  return TextField(
    controller: controller,
    style: const TextStyle(fontSize: 13),
    decoration: InputDecoration(hintText: hint, isDense: true),
  );
}

Widget _labeledField(String label, Widget field) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label,
          style: const TextStyle(fontSize: 12, color: Colors.white70)),
      const SizedBox(height: 6),
      field,
    ],
  );
}