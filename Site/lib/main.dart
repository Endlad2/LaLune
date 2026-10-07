// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// LaLune — точка входа веб-версии.
//
// Вся вёрстка — обычными Flutter-виджетами (Column, Row, Container),
// как в мобильном клиенте. Тёмная тема, стеклянные карточки, шрифт Nunito.
//
// Картинки грузятся по raw-ссылкам из GitHub (см. constants.dart).

import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const LaLuneWebApp());
}

class LaLuneWebApp extends StatelessWidget {
  const LaLuneWebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LaLune — кроссплатформенный VPN-клиент',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const HomePage(),
    );
  }
}
