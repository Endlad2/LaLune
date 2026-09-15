import 'package:flutter/material.dart';

/// Универсальное поле "label — значение" с прозрачным фоном и рамкой,
/// как в основном стиле LaLune.
class InputRow extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final bool readOnly;
  final int labelWidth;

  const InputRow({
    super.key,
    required this.label,
    required this.controller,
    this.keyboardType,
    this.readOnly = false,
    this.labelWidth = 130,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: labelWidth.toDouble(),
            child: Text(
              label,
              style: TextStyle(color: Colors.white.withOpacity(0.7)),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: keyboardType,
              readOnly: readOnly,
              style: const TextStyle(fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }
}
