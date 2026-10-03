// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';

import '../models/config_item.dart';
import 'glass_card.dart';

class ConfigSelector extends StatelessWidget {
  final List<ConfigItem> configs;
  final int? selectedId;
  final ValueChanged<ConfigItem> onSelect;
  final ValueChanged<int> onDelete;

  const ConfigSelector({
    super.key,
    required this.configs,
    required this.selectedId,
    required this.onSelect,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: GlassCard(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            if (configs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  'Нет конфигов. Нажмите + чтобы добавить',
                  style: TextStyle(color: Colors.white.withOpacity(0.5)),
                ),
              )
            else
              ...configs.map((c) => _ConfigRow(
                    config: c,
                    selected: c.id == selectedId,
                    onSelect: () => onSelect(c),
                    onDelete: () => onDelete(c.id),
                  )),
          ],
        ),
      ),
    );
  }
}

class _ConfigRow extends StatefulWidget {
  final ConfigItem config;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  const _ConfigRow({
    required this.config,
    required this.selected,
    required this.onSelect,
    required this.onDelete,
  });

  @override
  State<_ConfigRow> createState() => _ConfigRowState();
}

class _ConfigRowState extends State<_ConfigRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onSelect,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? const Color(0xFF4A6CF7).withOpacity(0.22)
                : Colors.white.withOpacity(_hover ? 0.06 : 0.02),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected
                  ? const Color(0xFF4A6CF7).withOpacity(0.55)
                  : Colors.white.withOpacity(0.08),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF4A6CF7).withOpacity(0.18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  widget.config.protocol,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF4A6CF7),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.config.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
              if (widget.selected)
                const Icon(Icons.check_circle,
                    size: 16, color: Color(0xFF7CFF9A)),
              const SizedBox(width: 6),
              IconButton(
                onPressed: widget.onDelete,
                splashRadius: 16,
                iconSize: 16,
                icon: Icon(Icons.close,
                    color: Colors.white.withOpacity(_hover ? 0.75 : 0.35)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
