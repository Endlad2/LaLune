// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune — точка входа Flutter-приложения.
//
// Архитектура:
//   Flutter UI ⟷ HTTP API (127.0.0.1:1062 или IP роутера) ⟷ платформенный бэкенд.
//
// Бэкенд запускается платформенным runner'ом:
//   * Linux   — main.cc запускает ~/.la-lune/LaLuneManager (через GUI sudo),
//               при закрытии окна шлёт POST /shutdown.
//   * Windows — main.cpp запускает %APPDATA%\.la-lune\LaLuneManager.exe
//               (манифест runas → UAC), WM_CLOSE → POST /shutdown.
//   * Android — MainActivity.onCreate → Backend(ctx).attachActivity(this).run(),
//               watchdog каждые 3 сек перезапускает Backend при смерти.
//   * iOS     — AppDelegate → Backend.shared.attach(window:).run(),
//               watchdog каждые 3 сек перезапускает Backend.
//
// OpenWRT:
//   Пользователь может подключиться к роутеру через
//   Настройки → Экспериментальное → Роутеры → «Подключить OpenWRT».
//   Тогда все API-запросы идут на IP роутера. Сверху показывается
//   зелёный баннер. При отключении — возврат на 127.0.0.1.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_watchdog.dart';
import 'pages/connection_page.dart';
import 'pages/info_page.dart';
import 'pages/logs_page.dart';
import 'pages/settings_page.dart';
import 'theme/app_theme.dart';
import 'widgets/navbar.dart';
import 'widgets/router_banner.dart';

void main() {
  runApp(const ProviderScope(child: LaLuneApp()));
}

class LaLuneApp extends StatelessWidget {
  const LaLuneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LaLune',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const RootShell(),
    );
  }
}

class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  int _currentPage = 0;


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(backendWatchdogProvider);
    });
  }

  // ConfigsNotifier already refreshes the list after add/delete. Avoid
  // remounting the whole page, which caused visible flashes on Android.
  void _reloadConnection() {}

  void _onNavSelect(int i) {
    if (i == _currentPage) return;
    setState(() => _currentPage = i);
  }

  Widget _buildPage() {
    switch (_currentPage) {
      case 0:
        return ConnectionPage(
          key: const ValueKey('connection'),
          onReload: _reloadConnection,
        );
      case 1:
        return const SettingsPage(key: ValueKey('settings'));
      case 2:
        return const InfoPage();
      case 3:
        return const LogsPage();
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final backendStatus = ref.watch(backendWatchdogProvider);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          image: DecorationImage(
            image: AssetImage('assets/background.png'),
            fit: BoxFit.cover,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Глобальный зелёный баннер, если подключены к OpenWRT-роутеру.
              const RouterBanner(),
              if (backendStatus == BackendStatus.dead)
                _BackendOfflineBanner(),
              Expanded(
                child: RepaintBoundary(
                  child: AnimatedSwitcher(
                    // Avoid cross-fading two translucent pages on top of each
                    // other: this produced ghosting/artifacts on some Android GPUs.
                    duration: Duration.zero,
                    transitionBuilder: (child, animation) => child,
                    child: KeyedSubtree(
                      key: ValueKey('page_$_currentPage'),
                      child: _buildPage(),
                    ),
                  ),
                ),
              ),
              NavBar(
                currentIndex: _currentPage,
                onSelect: _onNavSelect,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BackendOfflineBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFB22A2A),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: const Text(
        'Backend offline — перезапускаю...',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white, fontSize: 12),
      ),
    );
  }
}
