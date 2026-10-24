// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Настройки. deviceId удалён — новый CSQTT его не использует.
//
// ВАЖНО (исправление):
//   - vkHashes теперь ВСЕГДА берётся из `_vkHashesCtl.text` при сохранении,
//     а не подменяется на _selectedConfig.hashes. Иначе введённые вручную
//     хеши не сохранялись при переходе на другую вкладку.
//   - При загрузке: если у выбранного конфига хеши непустые — берём их,
//     иначе берём settings.vkHashes.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/config_item.dart';
import '../models/router_info.dart';
import '../models/settings.dart';
import '../models/vk_token_state.dart';
import '../state/configs_notifier.dart';
import '../state/router_notifier.dart';
import '../state/settings_notifier.dart';
import '../state/vk_notifier.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/glass_card.dart';
import '../widgets/input_row.dart';
import '../widgets/router_modal.dart';
import '../widgets/toast.dart';

const _pfTransports = <String>[
  'yandex',
  'vyandex',
  'boards',
  'mtslink',
  'cupsonline',
  'mailru',
  'oneme',
  'relayv2',
  'direct',
];

const _pfDocTransports = <String>{
  'yandex', 'vyandex', 'boards', 'mtslink', 'cupsonline', 'mailru', 'oneme',
};

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  Settings _s = Settings();
  ConfigItem? _selectedConfig;
  bool _loading = true;
  bool _busy = false;

  final _peerCtl = TextEditingController();
  final _vkHashesCtl = TextEditingController();
  final _passwordCtl = TextEditingController();
  final _workersCtl = TextEditingController();
  final _autoApiWorkersCtl = TextEditingController();
  final _clientIdsCtl = TextEditingController();
  final _deviceIdCtl = TextEditingController();

  // PaperFlux
  final _pfUrlCtl = TextEditingController();
  final _pfUrlsCtl = TextEditingController();
  final _pfVolgaCtl = TextEditingController();
  final _pfClientIpCtl = TextEditingController();
  final _pfRelayUrlCtl = TextEditingController();
  final _pfRelayTokenCtl = TextEditingController();
  final _pfRelaySessionCtl = TextEditingController();
  final _pfMaxTokenCtl = TextEditingController();
  final _pfMaxUidCtl = TextEditingController();

  String _pfTransport = 'yandex';
  String _pfMode = 'proxy';
  String _pfTcpRecovery = 'auto';

  String _authMode = 'manual';
  bool _enableSmartTunnel = false;
  bool _showCoreLogs = false;
  bool _shareVpn = false;

  bool get _isPaperFlux => _selectedConfig?.isPaperFlux == true;
  bool get _isCsqtt219 => _selectedConfig?.isCsqtt219 == true;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _peerCtl.dispose();
    _vkHashesCtl.dispose();
    _passwordCtl.dispose();
    _workersCtl.dispose();
    _autoApiWorkersCtl.dispose();
    _clientIdsCtl.dispose();
    _deviceIdCtl.dispose();
    _pfUrlCtl.dispose();
    _pfUrlsCtl.dispose();
    _pfVolgaCtl.dispose();
    _pfClientIpCtl.dispose();
    _pfRelayUrlCtl.dispose();
    _pfRelayTokenCtl.dispose();
    _pfRelaySessionCtl.dispose();
    _pfMaxTokenCtl.dispose();
    _pfMaxUidCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await ref.read(settingsProvider.notifier).reload();
    await ref.read(configsProvider.notifier).reload();
    if (!mounted) return;

    final s = ref.read(settingsProvider).data;
    final cfg = ref.read(configsProvider).selected;

    _s = s;
    _selectedConfig = cfg;

    if (cfg != null && !cfg.isPaperFlux) {
      _peerCtl.text = cfg.peer;
      _passwordCtl.text = cfg.password;
      // Показываем хеши из конфига, если они есть; иначе — из settings.
      _vkHashesCtl.text = cfg.hashes.isNotEmpty ? cfg.hashes : s.vkHashes;
    } else {
      _peerCtl.text = s.peer;
      _passwordCtl.text = s.password;
      _vkHashesCtl.text = s.vkHashes;
    }

    _workersCtl.text = s.workers.toString();
    _autoApiWorkersCtl.text = s.autoApiWorkers.toString();
    _clientIdsCtl.text = s.clientIds;
    _deviceIdCtl.text = s.deviceId;
    _authMode = s.authMode.isEmpty ? 'manual' : s.authMode;
    _enableSmartTunnel = s.enableSmartTunnel;
    _showCoreLogs = s.showCoreLogs;
    _shareVpn = s.shareVpn;

    _pfTransport = s.pfTransport.isEmpty ? 'yandex' : s.pfTransport;
    _pfMode = s.pfMode.isEmpty ? 'proxy' : s.pfMode;
    _pfTcpRecovery = s.pfTcpRecovery.isEmpty ? 'auto' : s.pfTcpRecovery;
    _pfUrlCtl.text = (cfg?.url.isNotEmpty == true) ? cfg!.url : s.pfUrl;
    _pfUrlsCtl.text = (cfg?.urls.isNotEmpty == true) ? cfg!.urls : s.pfUrls;
    _pfVolgaCtl.text =
        (cfg?.volgaUrl.isNotEmpty == true) ? cfg!.volgaUrl : s.pfVolgaUrl;
    _pfClientIpCtl.text =
        (cfg?.clientIp.isNotEmpty == true) ? cfg!.clientIp : s.pfClientIp;
    _pfRelayUrlCtl.text = s.pfRelayUrl;
    _pfRelayTokenCtl.text = s.pfRelayToken;
    _pfRelaySessionCtl.text = s.pfRelaySession;
    _pfMaxTokenCtl.text = s.pfMaxToken;
    _pfMaxUidCtl.text = s.pfMaxUid;

    setState(() => _loading = false);
  }

  void _markDirty() {
    if (!mounted) return;
    Toast.show(context, 'Сохраните настройки!',
        isError: true, duration: const Duration(seconds: 2));
  }

  Future<void> _save() async {
    setState(() => _busy = true);

    var w = int.tryParse(_workersCtl.text) ?? kDefaultWorkers;
    if (w < kMinWorkers) w = kMinWorkers;
    if (w > kMaxWorkers) w = kMaxWorkers;

    var aw = int.tryParse(_autoApiWorkersCtl.text) ?? kDefaultAutoApiWorkers;
    if (aw < kMinAutoApiWorkers) aw = kMinAutoApiWorkers;
    if (aw > kMaxAutoApiWorkers) aw = kMaxAutoApiWorkers;

    _workersCtl.text = w.toString();
    _autoApiWorkersCtl.text = aw.toString();

    // ВАЖНО: vkHashes всегда из контроллера — не подменяем на конфиг.
    // Это позволяет пользователю ввести хеши вручную и сохранить их
    // в settings.vkHashes. Backend fallback'ом возьмёт их, если у конфига
    // hashes пустые.
    final s = _s.copyWith(
      peer: _peerCtl.text.trim(),
      vkHashes: _vkHashesCtl.text.trim(),
      password: _passwordCtl.text,
      workers: w,
      autoApiWorkers: aw,
      clientIds: _clientIdsCtl.text.trim(),
      deviceId: _deviceIdCtl.text.trim(),
      authMode: _authMode,
      enableSmartTunnel: _enableSmartTunnel,
      showCoreLogs: _showCoreLogs,
      shareVpn: _shareVpn,
      pfTransport: _pfTransport,
      pfUrl: _pfUrlCtl.text.trim(),
      pfUrls: _pfUrlsCtl.text.trim(),
      pfVolgaUrl: _pfVolgaCtl.text.trim(),
      pfMode: _pfMode,
      pfTcpRecovery: _pfTcpRecovery,
      pfClientIp: _pfClientIpCtl.text.trim(),
      pfRelayUrl: _pfRelayUrlCtl.text.trim(),
      pfRelayToken: _pfRelayTokenCtl.text.trim(),
      pfRelaySession: _pfRelaySessionCtl.text.trim(),
      pfMaxToken: _pfMaxTokenCtl.text.trim(),
      pfMaxUid: _pfMaxUidCtl.text.trim(),
    );

    final ok = await ref.read(settingsProvider.notifier).save(s);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _s = s;
    });
    Toast.show(context,
        ok ? 'Настройки сохранены' : 'Ошибка сохранения настроек',
        isError: !ok);
  }

  void _setAuthMode(String mode, VkTokenState vk) {
    if (mode == 'autoApi' || mode == 'autoVk') {
      if (!vk.hasToken) {
        Toast.show(context, 'Требуется авторизация ВК', isError: true);
        return;
      }
    }
    setState(() => _authMode = mode);
    _markDirty();
  }

  Future<void> _onLoginTap() async {
    final vk = ref.read(vkProvider);
    if (vk.hasToken) {
      Toast.show(context, 'Токен ВК уже активен');
      return;
    }
    Toast.show(context, 'Открываю авторизацию ВК...');
    await ref.read(vkProvider.notifier).login();
  }

  Future<void> _onConnectRouter() async {
    final chosen = await showRouterModal(context);
    if (chosen == null || !mounted) return;
    final ok = await showConfirmDialog(
      context,
      title: 'Установить соединение?',
      message:
          'Все API-запросы будут переключены на ${chosen.displayName} '
          '(${chosen.ip}:1062).',
      confirmLabel: 'Подключить',
    );
    if (ok != true || !mounted) return;
    final success = await ref.read(routerProvider.notifier).connect(chosen);
    if (!mounted) return;
    if (success) {
      Toast.show(context, 'Подключено к роутеру ${chosen.displayName}');
    } else {
      final err = ref.read(routerProvider).error ?? 'Ошибка подключения';
      Toast.show(context, err, isError: true);
    }
  }

  Future<void> _onDisconnectRouter() async {
    final ok = await showConfirmDialog(
      context,
      title: 'Отключиться от роутера?',
      message: 'API вернётся на 127.0.0.1.',
      confirmLabel: 'Отключить',
    );
    if (ok != true || !mounted) return;
    await ref.read(routerProvider.notifier).disconnect();
  }

  Future<void> _onRemoveRouter(RouterInfo r) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Удалить роутер?',
      message: '${r.displayName} (${r.ip}) будет удалён.',
      confirmLabel: 'Удалить',
    );
    if (ok != true || !mounted) return;
    await ref.read(routerProvider.notifier).removeRouter(r.ip);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final vk = ref.watch(vkProvider);
    final routerState = ref.watch(routerProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sectionTitle('Основные настройки'),
              GlassCard(child: _buildMainBlock()),
              const SizedBox(height: 18),

              if (!_isPaperFlux) ...[
                _sectionTitle('Авторизация'),
                _buildAuthBlock(vk),
                const SizedBox(height: 18),
              ],

              _sectionTitle(_isPaperFlux ? 'Настройки PaperFlux' : 'Продвинутые настройки'),
              if (_isPaperFlux)
                GlassCard(child: _buildPaperFluxBlock())
              else
                GlassCard(child: _buildCsqttAdvancedBlock()),

              const SizedBox(height: 18),

              _sectionTitle('Экспериментальное'),
              GlassCard(
                  child: _buildExperimentalBlock(
                      routerState: routerState)),

              const SizedBox(height: 22),
              ElevatedButton(
                onPressed: _busy ? null : _save,
                child: Text(_busy ? 'Сохранение...' : 'Сохранить настройки'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMainBlock() {
    final cfg = _selectedConfig;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cfg != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                const Icon(Icons.link, size: 14, color: Color(0xFFB36AE2)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Конфиг: ${cfg.displayName} · ${cfg.protocol}',
                    style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.white.withOpacity(0.75)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'Конфиг не выбран. Выберите во вкладке «Подключение».',
              style:
                  TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.55)),
            ),
          ),

        if (!_isPaperFlux) ...[
          InputRow(label: 'Peer', controller: _peerCtl, readOnly: true),
          InputRow(
              label: 'Password', controller: _passwordCtl, readOnly: true),
        ],

        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              SizedBox(
                width: 130,
                child: Text('Workers',
                    style:
                        TextStyle(color: Colors.white.withOpacity(0.7))),
              ),
              Expanded(
                child: TextField(
                  controller: _workersCtl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(
                    hintText: '9',
                    helperText: 'От 1 до 127',
                    helperStyle: TextStyle(fontSize: 10.5),
                  ),
                  onChanged: (_) => _markDirty(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCsqttAdvancedBlock() {
    return Column(
      children: [
        _rowDropdown('Obfs', _s.obfs, const ['video', 'audio'], (v) {
          setState(() => _s = _s.copyWith(obfs: v));
          _markDirty();
        }),
        _rowDropdown('Fingerprint', _s.fingerprint,
            const ['firefox', 'chrome', 'edge'], (v) {
          setState(() => _s = _s.copyWith(fingerprint: v));
          _markDirty();
        }),
        _rowDropdown('Captcha Mode', _s.captchaMode,
            const ['auto', 'wv', 'rjs'], (v) {
          setState(() => _s = _s.copyWith(captchaMode: v));
          _markDirty();
        }),
        _rowDropdown('Turn Transport', _s.turnTransport,
            const ['udp', 'tcp'], (v) {
          setState(() => _s = _s.copyWith(turnTransport: v));
          _markDirty();
        }),
        InputRow(
            label: 'Client IDs',
            controller: _clientIdsCtl,
            onChanged: (_) => _markDirty()),
        _toggleRow('Allow hash redistribution', _s.allowHashRedistribution,
            (v) {
          setState(() => _s = _s.copyWith(allowHashRedistribution: v));
          _markDirty();
        }),
        _toggleRow('Validate VK hashes', _s.validateVkHashes, (v) {
          setState(() => _s = _s.copyWith(validateVkHashes: v));
          _markDirty();
        }),
        if (_isCsqtt219) ...[
          const SizedBox(height: 10),
          const _SubHeader('CSQTT 2.1.9'),
          InputRow(
            label: 'Device ID',
            controller: _deviceIdCtl,
            onChanged: (_) => _markDirty(),
          ),
        ],
      ],
    );
  }

  Widget _buildPaperFluxBlock() {
    final docTransport = _pfDocTransports.contains(_pfTransport);
    final relayTransport = _pfTransport == 'relayv2';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            children: [
              SizedBox(
                width: 150,
                child: Text('Транспорт',
                    style: TextStyle(color: Colors.white.withOpacity(0.7))),
              ),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _pfTransports.contains(_pfTransport)
                      ? _pfTransport
                      : _pfTransports.first,
                  dropdownColor: const Color(0xFF21142B),
                  items: _pfTransports
                      .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _pfTransport = v);
                    _markDirty();
                  },
                ),
              ),
            ],
          ),
        ),

        InputRow(
            label: 'Client IP',
            controller: _pfClientIpCtl,
            onChanged: (_) => _markDirty()),
        _rowDropdown('Mode', _pfMode, const ['proxy', 'raw'], (v) {
          setState(() => _pfMode = v);
          _markDirty();
        }),
        _rowDropdown('TCP Recovery', _pfTcpRecovery,
            const ['auto', 'classic', 'rack'], (v) {
          setState(() => _pfTcpRecovery = v);
          _markDirty();
        }),

        if (docTransport) ...[
          const SizedBox(height: 8),
          const _SubHeader('Документы'),
          InputRow(
              label: 'URL',
              controller: _pfUrlCtl,
              onChanged: (_) => _markDirty()),
          InputRow(
              label: 'URLs',
              controller: _pfUrlsCtl,
              onChanged: (_) => _markDirty()),
          InputRow(
              label: 'Volga URL',
              controller: _pfVolgaCtl,
              onChanged: (_) => _markDirty()),
        ],

        if (relayTransport) ...[
          const SizedBox(height: 8),
          const _SubHeader('Relay V2'),
          InputRow(
              label: 'Relay URL',
              controller: _pfRelayUrlCtl,
              onChanged: (_) => _markDirty()),
          InputRow(
              label: 'Relay Token',
              controller: _pfRelayTokenCtl,
              onChanged: (_) => _markDirty()),
          InputRow(
              label: 'Relay Session',
              controller: _pfRelaySessionCtl,
              onChanged: (_) => _markDirty()),
        ],

        if (_pfTransport == 'oneme' || _pfTransport == 'mailru' || _pfTransport == 'boards') ...[
          const SizedBox(height: 8),
          const _SubHeader('MAX / OneMe'),
          InputRow(
              label: 'MAX Token',
              controller: _pfMaxTokenCtl,
              onChanged: (_) => _markDirty()),
          InputRow(
              label: 'MAX Uid',
              controller: _pfMaxUidCtl,
              onChanged: (_) => _markDirty()),
        ],
      ],
    );
  }

  Widget _buildAuthBlock(VkTokenState vk) {
    final hasToken = vk.hasToken;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('РЕЖИМ АВТОРИЗАЦИИ',
                  style: TextStyle(
                      fontSize: 10.5,
                      letterSpacing: 0.7,
                      fontWeight: FontWeight.w700,
                      color: Colors.white.withOpacity(0.4))),
              const SizedBox(height: 10),
              _authOption('manual', 'Ручной', 'Ввести хеши вручную',
                  enabled: true, vk: vk),
              _authOption('autoApi', 'Авто API',
                  'Создавать звонки через VK API',
                  enabled: hasToken, vk: vk),
              _authOption('autoVk', 'Авто ВК',
                  'Ядро само авторизуется через VK',
                  enabled: hasToken, vk: vk),
              const SizedBox(height: 12),
              if (!hasToken)
                _buildLoginButton(vk)
              else
                _buildTokenActiveBadge(),
              if (vk.fetching) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: vk.progress / 100.0,
                  backgroundColor: Colors.white.withOpacity(0.1),
                  valueColor:
                      const AlwaysStoppedAnimation(Color(0xFFFFB347)),
                  minHeight: 4,
                ),
                const SizedBox(height: 6),
                Text(vk.message,
                    style: TextStyle(
                        fontSize: 11, color: Colors.white.withOpacity(0.6))),
              ],
              if (_authMode == 'manual') ...[
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('Хеши (через запятую или +)',
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.65))),
                ),
                TextField(
                  controller: _vkHashesCtl,
                  minLines: 2,
                  maxLines: 4,
                  style: const TextStyle(fontSize: 13),
                  decoration:
                      const InputDecoration(hintText: 'hash1,hash2,hash3'),
                  onChanged: (_) => _markDirty(),
                ),
              ],
            ],
          ),
        ),
        if (_authMode == 'autoApi') ...[
          const SizedBox(height: 14),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('АВТО API',
                    style: TextStyle(
                        fontSize: 10.5,
                        letterSpacing: 0.7,
                        fontWeight: FontWeight.w700,
                        color: Colors.white.withOpacity(0.4))),
                const SizedBox(height: 10),
                Row(
                  children: [
                    SizedBox(
                      width: 170,
                      child: Text('Воркеров на хеш',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.7))),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _autoApiWorkersCtl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(fontSize: 13.5),
                        decoration: const InputDecoration(
                          hintText: '9',
                          helperText: 'От 9 до 27',
                          helperStyle: TextStyle(fontSize: 10.5),
                        ),
                        onChanged: (_) => _markDirty(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildExperimentalBlock({required RouterState routerState}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _toggleRow('Раздавать VPN', _shareVpn, (v) {
          setState(() => _shareVpn = v);
          _markDirty();
        }),
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 4, bottom: 6),
          child: Text(
            'Открывает SOCKS5-прокси на случайном свободном порту '
            '(не 1080). Порт виден в /vpn/status как socks5Port.',
            style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: Colors.white.withOpacity(0.55)),
          ),
        ),
        _toggleRow('Показывать логи ядра', _showCoreLogs, (v) {
          setState(() => _showCoreLogs = v);
          _markDirty();
        }),
        _toggleRow('Enable SmartTunnel', _enableSmartTunnel, (v) {
          setState(() => _enableSmartTunnel = v);
          _markDirty();
        }),
        const SizedBox(height: 14),
        const Divider(height: 1),
        const SizedBox(height: 14),
        Text('РОУТЕРЫ',
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.7,
              fontWeight: FontWeight.w700,
              color: Colors.white.withOpacity(0.4),
            )),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _onConnectRouter,
            icon: const Icon(Icons.router, size: 16),
            label: const Text('Подключить OpenWRT'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF7518),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        if (routerState.activeRouter != null) ...[
          const SizedBox(height: 10),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF8E44AD).withOpacity(0.18),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: const Color(0xFF8E44AD).withOpacity(0.55)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle,
                    size: 16, color: Color(0xFFB36AE2)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Подключено к '
                    '${routerState.activeRouter!.displayName}',
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: _onDisconnectRouter,
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent),
                  child: const Text('Отключить'),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (routerState.savedRouters.isEmpty)
          Text(
            'Сохранённых роутеров нет',
            style: TextStyle(
              fontSize: 11.5,
              color: Colors.white.withOpacity(0.45),
            ),
          )
        else
          ...routerState.savedRouters.map((r) {
            final active = routerState.activeRouter?.ip == r.ip;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: active
                      ? const Color(0xFFFF7518).withOpacity(0.14)
                      : Colors.white.withOpacity(0.03),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: active
                        ? const Color(0xFFFF7518).withOpacity(0.5)
                        : Colors.white.withOpacity(0.08),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.router,
                        size: 16, color: Colors.white70),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r.displayName,
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600)),
                          Text('${r.ip}:1062',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white.withOpacity(0.55),
                              )),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Удалить',
                      onPressed: () => _onRemoveRouter(r),
                      iconSize: 16,
                      icon: Icon(Icons.delete_outline,
                          color: Colors.white.withOpacity(0.5)),
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _authOption(String value, String title, String subtitle,
      {required bool enabled, required VkTokenState vk}) {
    final selected = _authMode == value;
    final opacity = enabled ? 1.0 : 0.4;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Opacity(
        opacity: opacity,
        child: InkWell(
          onTap: enabled ? () => _setAuthMode(value, vk) : null,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFFFF7518).withOpacity(0.18)
                  : Colors.white.withOpacity(0.02),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? const Color(0xFFFF7518).withOpacity(0.55)
                    : Colors.white.withOpacity(0.08),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 18,
                  color: selected
                      ? const Color(0xFFFF7518)
                      : Colors.white.withOpacity(0.4),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w600)),
                      Text(subtitle,
                          style: TextStyle(
                              fontSize: 11.5,
                              color: Colors.white.withOpacity(0.55))),
                    ],
                  ),
                ),
                if (!enabled)
                  Icon(Icons.lock_outline,
                      size: 14, color: Colors.white.withOpacity(0.5)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoginButton(VkTokenState vk) {
    if (vk.fetching) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: null,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text('Ожидание... ${vk.progress}%'),
            ],
          ),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _onLoginTap,
        icon: const Icon(Icons.login, size: 16),
        label: const Text('Войти'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: BorderSide(color: Colors.white.withOpacity(0.2)),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  Widget _buildTokenActiveBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFB36AE2).withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFB36AE2).withOpacity(0.45)),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text('Активно',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            tooltip: 'Сбросить токен',
            onPressed: () async {
              await ref.read(vkProvider.notifier).deleteToken();
              if (!mounted) return;
              setState(() => _authMode = 'manual');
              Toast.show(context, 'Токен ВК удалён');
            },
            icon: const Icon(Icons.delete_outline, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(text,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: Colors.white.withOpacity(0.55))),
    );
  }

  Widget _rowDropdown(String label, String value, List<String> items,
      ValueChanged<String> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(label,
                style: TextStyle(color: Colors.white.withOpacity(0.7))),
          ),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: items.contains(value) ? value : items.first,
              dropdownColor: const Color(0xFF21142B),
              items: items
                  .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                  .toList(),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggleRow(String label, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(color: Colors.white.withOpacity(0.7))),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: const Color(0xFFFFB347),
          ),
        ],
      ),
    );
  }
}

class _SubHeader extends StatelessWidget {
  final String text;
  const _SubHeader(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4, left: 2),
      child: Text(text.toUpperCase(),
          style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.7,
              fontWeight: FontWeight.w700,
              color: Colors.white.withOpacity(0.4))),
    );
  }
}
