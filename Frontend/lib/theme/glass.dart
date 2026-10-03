// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';

/// Общий стиль "стеклянной" карточки — прозрачный фон + blur + рамка.
BoxDecoration glassCard({double radius = 14, double opacity = 0.08}) {
  return BoxDecoration(
    color: Colors.white.withOpacity(opacity),
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: Colors.white.withOpacity(0.12), width: 1),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.25),
        blurRadius: 18,
        offset: const Offset(0, 6),
      ),
    ],
  );
}
