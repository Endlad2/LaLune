// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Тема приложения. Использует DialogThemeData — актуальный API
// Flutter 3.29+. DialogTheme (старый) удалён в Flutter 3.47.

import 'package:flutter/material.dart';

const Color kAccent = Color(0xFF4A6CF7);
const Color kAccentYellow = Color(0xFFF7E84E);
const Color kAccentGreen = Color(0xFF7CFF9A);
const Color kBackground = Color(0xFF0A0E2A);
const Color kSurface = Color(0xFF0F1540);

ThemeData buildAppTheme() {
  final base = ThemeData.dark(useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: base.colorScheme.copyWith(
      primary: kAccent,
      secondary: kAccentYellow,
      surface: kSurface.withOpacity(0.55),
    ),
    textTheme: base.textTheme.apply(
      fontFamily: 'Nunito',
      bodyColor: Colors.white,
      displayColor: Colors.white,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withOpacity(0.06),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.12)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.12)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kAccent, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: kAccent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 0,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Colors.white70),
    ),
    // DialogThemeData — актуальное имя класса в Flutter 3.29+.
    dialogTheme: const DialogThemeData(
      backgroundColor: kSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
  );
}
