// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Общий скаффолд: фоновое изображение + затемняющий слой + скролл.

import 'package:flutter/material.dart';

import '../constants.dart';

class GlassScaffold extends StatelessWidget {
  final Widget child;
  final ScrollController? scrollController;

  const GlassScaffold({
    super.key,
    required this.child,
    this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Фон
          Positioned.fill(
            child: Image.network(
              Links.background,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: const Color(0xFF0A0E2A),
              ),
            ),
          ),
          // Затемняющий слой (для контраста)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFF0A0E2A).withOpacity(0.55),
                    const Color(0xFF0A0E2A).withOpacity(0.85),
                    const Color(0xFF0A0E2A).withOpacity(0.95),
                  ],
                ),
              ),
            ),
          ),
          // Контент
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}
