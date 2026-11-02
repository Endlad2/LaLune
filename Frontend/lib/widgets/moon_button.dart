// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';

import '../theme/assets.dart';

class MoonButton extends StatefulWidget {
  final bool connected;
  final VoidCallback onTap;

  const MoonButton({super.key, required this.connected, required this.onTap});

  @override
  State<MoonButton> createState() => _MoonButtonState();
}

class _MoonButtonState extends State<MoonButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final glow = widget.connected
        ? const Color(0xFF7CFF9A).withOpacity(0.55)
        : const Color(0xFFF7E84E).withOpacity(_hover ? 0.45 : 0.2);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 0.94 : 1.0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: glow,
                  blurRadius: 34,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: Image.asset(
              Assets.lune,
              width: 130,
              height: 130,
              errorBuilder: (_, __, ___) => Container(
                width: 130,
                height: 130,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF1A1A3E),
                ),
                child: const Icon(Icons.dark_mode,
                    size: 72, color: Color(0xFFF7E84E)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
