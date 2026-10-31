// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'dart:async';

import 'package:flutter/material.dart';

import '../state/openwrt_installer.dart';
import '../state/router_scanner.dart';

Future<String?> showOpenWrtActionDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.65),
    builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF21142B),
      title: const Text('OpenWRT'),
      content: const Text('Что сделать с роутером?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        OutlinedButton.icon(
          onPressed: () => Navigator.pop(context, 'install'),
          icon: const Icon(Icons.download, size: 17),
          label: const Text('Установить'),
        ),
        ElevatedButton.icon(
          onPressed: () => Navigator.pop(context, 'connect'),
          icon: const Icon(Icons.link, size: 17),
          label: const Text('Подключиться'),
        ),
      ],
    ),
  );
}

Future<void> showOpenWrtInstallFlow(BuildContext context) async {
  final host = await showDialog<String>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.65),
    builder: (_) => const _SshHostModal(),
  );
  if (host == null || !context.mounted) return;

  final credentials = await _showCredentialsDialog(context, host);
  if (credentials == null || !context.mounted) return;

  // showDialog completes as soon as Navigator.pop is called, while the route can
  // still be in its exit transition. Waiting for the frame prevents a second
  // overlay route from being pushed while inherited dependencies of the first
  // dialog are still deactivating on some Flutter/Android combinations.
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withOpacity(0.7),
    builder: (_) => _InstallProgressDialog(
      host: host,
      username: credentials.username,
      password: credentials.password,
    ),
  );
}

class _SshCredentials {
  final String username;
  final String password;

  const _SshCredentials(this.username, this.password);
}

Future<_SshCredentials?> _showCredentialsDialog(
  BuildContext context,
  String host,
) {
  return showDialog<_SshCredentials>(
    context: context,
    barrierColor: Colors.black.withOpacity(0.65),
    builder: (_) => _SshCredentialsDialog(host: host),
  );
}

class _SshCredentialsDialog extends StatefulWidget {
  final String host;

  const _SshCredentialsDialog({required this.host});

  @override
  State<_SshCredentialsDialog> createState() => _SshCredentialsDialogState();
}

class _SshCredentialsDialogState extends State<_SshCredentialsDialog> {
  late final TextEditingController _userCtl;
  late final TextEditingController _passCtl;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _userCtl = TextEditingController(text: 'root');
    _passCtl = TextEditingController();
  }

  void _submit() {
    final user = _userCtl.text.trim();
    if (user.isEmpty) return;
    FocusScope.of(context).unfocus();
    Navigator.pop(context, _SshCredentials(user, _passCtl.text));
  }

  @override
  void dispose() {
    _userCtl.dispose();
    _passCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF21142B),
      title: Text('SSH · ${widget.host}'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _userCtl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Логин SSH',
                hintText: 'root',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _passCtl,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Пароль SSH (может быть пустым)',
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 10),
            Text(
              'Клиент подключится к порту 22, создаст ~/la-lune/, '
              'установит backend и при необходимости CSQTT-ядро.',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: Colors.white.withOpacity(0.55),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        ElevatedButton(
          onPressed: _submit,
          child: const Text('Продолжить'),
        ),
      ],
    );
  }
}

class _SshHostModal extends StatefulWidget {
  const _SshHostModal();

  @override
  State<_SshHostModal> createState() => _SshHostModalState();
}

class _SshHostModalState extends State<_SshHostModal> {
  final _ipCtl = TextEditingController();
  final List<String> _hosts = [];
  StreamSubscription<String>? _scanSub;
  bool _scanning = false;
  bool _showManual = false;
  bool _checkingManual = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    await _scanSub?.cancel();
    if (!mounted) return;
    setState(() {
      _hosts.clear();
      _scanning = true;
      _error = null;
    });
    _scanSub = RouterScanner.scanSshHosts().listen(
      (host) {
        if (!mounted || _hosts.contains(host)) return;
        setState(() {
          _hosts.add(host);
          _hosts.sort(_compareIp);
        });
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _scanning = false;
          _error = '$e';
        });
      },
    );
  }

  Future<void> _submitManual() async {
    final host = _ipCtl.text.trim();
    if (host.isEmpty || _checkingManual) return;
    setState(() {
      _checkingManual = true;
      _error = null;
    });
    final open = await RouterScanner.isPortOpen(
      host,
      22,
      timeout: const Duration(seconds: 2),
    );
    if (!mounted) return;
    setState(() => _checkingManual = false);
    if (open) {
      Navigator.pop(context, host);
    } else {
      setState(() => _error = 'SSH-порт $host:22 не отвечает');
    }
  }

  static int _compareIp(String a, String b) {
    final aa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final bb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    for (var i = 0; i < 4; i++) {
      final av = i < aa.length ? aa[i] : 0;
      final bv = i < bb.length ? bb[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return a.compareTo(b);
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _ipCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF21142B),
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Установить OpenWRT',
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
              Row(
                children: [
                  if (_scanning) ...[
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    const Text('Ищем устройства с открытым SSH :22...'),
                  ] else ...[
                    Text('Найдено: ${_hosts.length}'),
                    const Spacer(),
                    TextButton(
                      onPressed: _startScan,
                      child: const Text('Сканировать снова'),
                    ),
                  ],
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ],
              const SizedBox(height: 8),
              Expanded(
                child: _hosts.isEmpty
                    ? Center(
                        child: Text(
                          _scanning
                              ? 'Сканируем локальную сеть...'
                              : 'SSH-устройства не найдены',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _hosts.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 6),
                        itemBuilder: (_, i) {
                          final host = _hosts[i];
                          return InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => Navigator.pop(context, host),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 11,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.04),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.08),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.terminal, size: 18),
                                  const SizedBox(width: 10),
                                  Expanded(child: Text('$host:22')),
                                  const Icon(Icons.chevron_right, size: 18),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              if (!_showManual)
                OutlinedButton.icon(
                  onPressed: () => setState(() => _showManual = true),
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('Ввести IP вручную'),
                )
              else ...[
                TextField(
                  controller: _ipCtl,
                  autofocus: true,
                  keyboardType: TextInputType.url,
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
                        onPressed: _checkingManual
                            ? null
                            : () => setState(() => _showManual = false),
                        child: const Text('Отмена'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _checkingManual ? null : _submitManual,
                        child: _checkingManual
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Проверить :22'),
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

class _InstallProgressDialog extends StatefulWidget {
  final String host;
  final String username;
  final String password;

  const _InstallProgressDialog({
    required this.host,
    required this.username,
    required this.password,
  });

  @override
  State<_InstallProgressDialog> createState() => _InstallProgressDialogState();
}

class _InstallProgressDialogState extends State<_InstallProgressDialog> {
  String _status = 'Подготовка...';
  OpenWrtInstallResult? _result;

  @override
  void initState() {
    super.initState();
    Future.microtask(_run);
  }

  Future<void> _run() async {
    final result = await OpenWrtInstaller.install(
      host: widget.host,
      username: widget.username,
      password: widget.password,
      onProgress: (message) {
        if (mounted) setState(() => _status = message);
      },
    );
    if (mounted) setState(() => _result = result);
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return PopScope(
      canPop: result != null,
      child: AlertDialog(
        backgroundColor: const Color(0xFF21142B),
        title: Text(result == null
            ? 'Установка OpenWRT'
            : (result.ok ? 'Готово' : 'Ошибка установки')),
        content: SizedBox(
          width: 430,
          child: result == null
              ? Row(
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    const SizedBox(width: 14),
                    Expanded(child: Text(_status)),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(result.message),
                    if (!result.ok && result.log.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 180),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.22),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            result.log,
                            style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
        ),
        actions: result == null
            ? null
            : [
                ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Готово'),
                ),
              ],
      ),
    );
  }
}
