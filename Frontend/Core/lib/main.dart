// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// main.dart — точка входа нативного Flutter-приложения.
//
// Инициализирует Api (FFI или MethodChannel) и запускает RootShell.

import 'package:flutter/material.dart';

import 'api.dart';
import 'theme.dart';
import 'pages/connection_page.dart';
import 'pages/settings_page.dart';
import 'pages/logs_page.dart';
import 'pages/info_page.dart';
import 'widgets/navbar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Api.init();
  runApp(const LaLuneApp());
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

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _currentPage = 0;
  int _connectionVersion = 0;
  int _settingsVersion = 0;

  void _reloadConnection() {
    setState(() => _connectionVersion++);
  }

  void _onNavSelect(int i) {
    if (i == _currentPage) return;
    setState(() {
      _currentPage = i;
      if (i == 1) {
        _settingsVersion++;
      }
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
        return SettingsPage(
          key: ValueKey('settings_$_settingsVersion'),
        );
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
