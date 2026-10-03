// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune — точка входа Flutter-приложения.
//
// Архитектура:
//   Flutter UI ⟷ HTTP API (127.0.0.1:1062) ⟷ платформенный бэкенд.
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_watchdog.dart';
import 'pages/connection_page.dart';
import 'pages/info_page.dart';
import 'pages/logs_page.dart';
import 'pages/settings_page.dart';
import 'theme/app_theme.dart';
import 'widgets/navbar.dart';

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

  int _connectionVersion = 0;
  int _settingsVersion = 0;

  @override
  void initState() {
    super.initState();
    // Прогреваем watchdog — он стартует в конструкторе провайдера.
    // Просто читаем провайдер, чтобы он инициализировался.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(backendWatchdogProvider);
    });
  }

  void _reloadConnection() {
    setState(() => _connectionVersion++);
  }

  void _onNavSelect(int i) {
    if (i == _currentPage) return;
    setState(() {
      _currentPage = i;
      if (i == 1) _settingsVersion++;
    });
  }

  Widget _buildPage() {
    switch (_currentPage) {
      case 0:
        return ConnectionPage(
          key: ValueKey('connection_$_connectionVersion'),
          onReload: _reloadConnection,
        );
      case 1:
        return SettingsPage(key: ValueKey('settings_$_settingsVersion'));
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
              if (backendStatus == BackendStatus.dead)
                _BackendOfflineBanner(),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.04),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    );
                  },
                  child: KeyedSubtree(
                    key: ValueKey('page_$_currentPage'),
                    child: _buildPage(),
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
