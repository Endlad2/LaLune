// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';

import '../models/config_item.dart';
import 'glass_card.dart';
import 'toast.dart';

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
    // Цвет бейджа зависит от протокола.
    final badgeColor = widget.config.isPaperFlux
        ? const Color(0xFFFFB347)
        : const Color(0xFFFF7518);

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
                ? badgeColor.withOpacity(0.22)
                : Colors.white.withOpacity(_hover ? 0.06 : 0.02),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected
                  ? badgeColor.withOpacity(0.55)
                  : Colors.white.withOpacity(0.08),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  widget.config.protocol,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: badgeColor,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.config.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5),
                    ),
                    if (widget.config.isPaperFlux &&
                        widget.config.transport.isNotEmpty)
                      Text(
                        widget.config.transport,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: Colors.white.withOpacity(0.5),
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.config.isCsqtt251)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Toast.show(
                      context,
                      'CSQTT 2.5.1: возможны проблемы с DTLS, совместимостью соединения и стабильностью туннеля. Если подключение не работает, попробуйте CSQTT 2.1.9.',
                      duration: const Duration(seconds: 5),
                    ),
                    child: Container(
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFB347),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Text(
                        '!',
                        style: TextStyle(
                          color: Color(0xFF302900),
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                ),
              if (widget.selected)
                const Icon(Icons.check_circle,
                    size: 16, color: Color(0xFFB36AE2)),
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
