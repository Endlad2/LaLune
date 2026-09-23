import 'dart:ui';
import 'package:flutter/material.dart';

class NavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onSelect;

  const NavBar({
    super.key,
    required this.currentIndex,
    required this.onSelect,
  });

  static const _items = [
    _NavItem(icon: 'assets/connect.png', label: 'Подключение'),
    _NavItem(icon: 'assets/settings.png', label: 'Настройки'),
    _NavItem(icon: 'assets/info.png', label: 'Информация'),
    _NavItem(icon: 'assets/logs.png', label: 'Логи'),
    _NavItem(icon: 'assets/deploy.png', label: 'Деплой'),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Colors.white.withOpacity(0.12),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: List.generate(_items.length, (i) {
                return _NavButton(
                  item: _items[i],
                  selected: i == currentIndex,
                  onTap: () => onSelect(i),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final String icon;
  final String label;
  const _NavItem({required this.icon, required this.label});
}

class _NavButton extends StatefulWidget {
  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _NavButtonState extends State<_NavButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected;
    final scale = _hover ? 0.92 : 1.0;

    // Иконка НЕ перекрашивается — показываем PNG как есть.
    // Подсветка идёт через подложку-капсулу под иконкой + label.
    final chipColor = active
        ? const Color(0xFFF7E84E).withOpacity(0.18)
        : (_hover
            ? Colors.white.withOpacity(0.10)
            : Colors.transparent);

    final chipBorder = active
        ? const Color(0xFFF7E84E).withOpacity(0.75)
        : (_hover
            ? Colors.white.withOpacity(0.22)
            : Colors.transparent);

    final labelColor = active
        ? const Color(0xFFF7E84E)
        : Colors.white.withOpacity(_hover ? 0.95 : 0.55);

    // Активная — чуть ярче, hover — с лёгким усилением.
    final iconOpacity = active
        ? 1.0
        : (_hover ? 1.0 : 0.85);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: scale,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: chipColor,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: chipBorder, width: 1),
                    boxShadow: active
                        ? [
                            BoxShadow(
                              color: const Color(0xFFF7E84E)
                                  .withOpacity(0.35),
                              blurRadius: 16,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: AnimatedOpacity(
                    opacity: iconOpacity,
                    duration: const Duration(milliseconds: 180),
                    // Оригинальный цветной PNG, без всяких фильтров.
                    child: Image.asset(
                      widget.item.icon,
                      width: 26,
                      height: 26,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.circle_outlined,
                        size: 26,
                        color: active
                            ? const Color(0xFFF7E84E)
                            : Colors.white.withOpacity(0.7),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                  color: labelColor,
                ),
                child: Text(widget.item.label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
