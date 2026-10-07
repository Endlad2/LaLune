// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Тёмная тема, как в мобильном клиенте. Цвета и стили вынесены в
// константы, чтобы использовать их в виджетах напрямую.

import 'package:flutter/material.dart';

// ---------- Палитра (совпадает с мобильным клиентом) ----------
const Color kAccent        = Color(0xFF4A6CF7); // синий
const Color kAccentYellow  = Color(0xFFF7E84E); // жёлтый (луна)
const Color kAccentGreen   = Color(0xFF7CFF9A); // зелёный (ok)
const Color kBackground    = Color(0xFF0A0E2A); // тёмно-синий фон
const Color kSurface       = Color(0xFF0F1540); // поверхность карточек
const Color kTextPrimary   = Colors.white;
const Color kTextSecondary = Color(0xB3FFFFFF); // white70
const Color kTextMuted     = Color(0x80FFFFFF); // white50

ThemeData buildAppTheme() {
  final base = ThemeData.dark(useMaterial3: true);

  return base.copyWith(
    scaffoldBackgroundColor: kBackground,
    colorScheme: base.colorScheme.copyWith(
      primary: kAccent,
      secondary: kAccentYellow,
      surface: kSurface,
    ),
    textTheme: base.textTheme.apply(
      fontFamily: 'Nunito',
      bodyColor: kTextPrimary,
      displayColor: kTextPrimary,
    ),
    // Nunito подключаем через google_fonts в HomePage, но на всякий
    // случай оставляем fallback.
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
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: kAccent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        elevation: 0,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Colors.white70),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: kSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white.withOpacity(0.15)),
      thickness: WidgetStateProperty.all(6),
    ),
  );
}
