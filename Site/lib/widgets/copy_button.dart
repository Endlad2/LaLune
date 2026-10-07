// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Кнопка "скопировать в буфер обмена" с визуальным подтверждением.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CopyButton extends StatefulWidget {
  final String value;
  final String? label;

  const CopyButton({super.key, required this.value, this.label});

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.value));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future.delayed(const Duration(milliseconds: 1400));
    if (!mounted) return;
    setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _copied ? 'Скопировано!' : 'Скопировать',
      child: InkWell(
        onTap: _copy,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: _copied
                ? const Color(0xFF7CFF9A).withOpacity(0.18)
                : Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _copied
                  ? const Color(0xFF7CFF9A).withOpacity(0.55)
                  : Colors.white.withOpacity(0.12),
            ),
          ),
          child: Icon(
            _copied ? Icons.check : Icons.copy_rounded,
            size: 16,
            color: _copied ? const Color(0xFF7CFF9A) : Colors.white70,
          ),
        ),
      ),
    );
  }
}
