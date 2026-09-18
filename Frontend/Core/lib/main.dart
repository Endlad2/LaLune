// SPDX-FileCopyrightText: 2026 luminescq
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// main.dart — точка входа нативного Flutter-приложения.
//
// Инициализирует Api (FFI или MethodChannel) и запускает RootShell.
// Ошибки инициализации пишутся в файл ~/.la-lune/init_error.log
// (Desktop) или app_files/la-lune/init_error.log (Android),
// потому что в релизной сборке консоли нет и ошибку не видно.

import 'dart:io' show File, Platform, Directory;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'api.dart';
import 'theme.dart';
import 'pages/connection_page.dart';
import 'pages/settings_page.dart';
import 'pages/logs_page.dart';
import 'pages/info_page.dart';
import 'widgets/navbar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  String? initError;
  try {
    await Api.init();
  } catch (e, st) {
    initError = '$e\n\n$st';
    _writeInitError(initError);
  }

  runApp(LaLuneApp(initError: initError));
}

/// Пишем ошибку инициализации в файл рядом с данными приложения.
void _writeInitError(String text) {
  try {
    final home = Platform.environment['USERPROFILE']
        ?? Platform.environment['HOME']
        ?? '.';
    final dir = Directory(p.join(home, '.la-lune'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final f = File(p.join(dir.path, 'init_error.log'));
    f.writeAsStringSync(
      '[${DateTime.now().toIso8601String()}]\n$text\n',
    );
  } catch (_) {
    // Если и это не удалось — ничего не делаем.
  }
}

class LaLuneApp extends StatelessWidget {
  /// Текст ошибки инициализации Api, если она была.
  final String? initError;

  const LaLuneApp({super.key, this.initError});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LaLune',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: initError == null
          ? const RootShell()
          : _InitErrorScreen(message: initError!),
    );
  }
}

/// Экран, который показывается, если Api.init() упал.
/// Раньше приложение просто молча не открывалось.
class _InitErrorScreen extends StatelessWidget {
  final String message;
  const _InitErrorScreen({required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E2A),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.error_outline,
                        color: Color(0xFFFF8A8A), size: 28),
                    SizedBox(width: 12),
                    Text(
                      'Ошибка инициализации ядра',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'LaLune не смог загрузить lalune.dll (или аналог для '
                  'вашей платформы). Убедитесь, что рядом с .exe лежат:\n'
                  '  • lalune.dll (или liblalune.so на Linux)\n'
                  '  • flutter_windows.dll\n'
                  '  • папка data/\n\n'
                  'Подробности также записаны в файл init_error.log '
                  'в папке ~/.la-lune/.',
                  style: TextStyle(color: Colors.white70, height: 1.5),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.1),
                    ),
                  ),
                  child: SelectableText(
                    message,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.45,
                      color: Color(0xFFFFE0E0),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
