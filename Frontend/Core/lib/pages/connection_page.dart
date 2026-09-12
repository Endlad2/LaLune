import 'package:flutter/material.dart';

import '../api.dart';
import '../widgets/glass_card.dart';

class ConnectionPage extends StatefulWidget {
  /// Вызывается, когда конфиг добавлен/удалён — родитель должен
  /// пересоздать эту страницу (инкрементить свой version-key).
  final VoidCallback? onReload;

  const ConnectionPage({super.key, this.onReload});

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  List<ConfigItem> _configs = [];
  int? _selectedId;
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    _reload();
    _startPolling();
  }

  void _reload() {
    final cfgs = Api.getConfigs();
    setState(() {
      _configs = cfgs;
      if (cfgs.isNotEmpty &&
          (_selectedId == null ||
              !cfgs.any((c) => c.id == _selectedId))) {
        _selectedId = cfgs.first.id;
      }
      _connected = Api.isConnected();
    });
  }

  void _startPolling() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return false;
      final c = Api.isConnected();
      if (c != _connected) setState(() => _connected = c);
      return true;
    });
  }

  void _toggle() {
    if (_connected) {
      Api.disconnect();
      setState(() => _connected = false);
    } else {
      if (_selectedId == null) {
        _toast('Выберите конфиг');
        return;
      }
      final ok = Api.connect(_selectedId!);
      if (ok) setState(() => _connected = true);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        backgroundColor: Colors.black.withOpacity(0.8),
      ),
    );
  }

  Future<void> _showAddDialog() async {
    final controller = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F1540),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
        title: const Text('Добавить конфиг'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            minLines: 2,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              hintText:
                  'csqtt://connect?v=2&host=...&peer=...&password=...&hashes=...',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );

    if (ok == true) {
      final link = controller.text.trim();
      if (link.isEmpty) {
        _toast('Введите ссылку');
        controller.dispose();
        return;
      }
      final saved = Api.saveConfig(link);
      if (saved) {
        _toast('Конфиг сохранён');
        // Локально обновим список, а затем попросим родителя
        // пересоздать всю страницу — так UI гарантированно
        // показывает актуальные данные, включая состояние
        // выбранного конфига и флаг подключения.
        _reload();
        widget.onReload?.call();
      } else {
        _toast('Ошибка сохранения');
      }
    }

    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MoonButton(
                  connected: _connected,
                  onTap: _toggle,
                ),
                const SizedBox(height: 20),
                Text(
                  _connected ? 'Подключено' : 'Отключено',
                  style: TextStyle(
                    fontSize: 16,
                    color: _connected
                        ? const Color(0xFF7CFF9A)
                        : Colors.white.withOpacity(0.6),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 22),
                _ConfigSelector(
                  configs: _configs,
                  selectedId: _selectedId,
                  onSelect: (id) => setState(() => _selectedId = id),
                  onDelete: (id) async {
                    final ok = await _confirmDelete();
                    if (ok == true) {
                      Api.deleteConfig(id);
                      _reload();
                      widget.onReload?.call();
                    }
                  },
                ),
              ],
            ),
          ),
        ),

        Positioned(
          top: 12,
          right: 16,
          child: _AddButton(onTap: _showAddDialog),
        ),
      ],
    );
  }

  Future<bool?> _confirmDelete() {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F1540),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
        title: const Text('Удалить конфиг?'),
        content: const Text(
          'Это действие нельзя отменить.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
  }
}

// ============================================================
//  Кнопка "+" в правом верхнем углу
// ============================================================

class _AddButton extends StatefulWidget {
  final VoidCallback onTap;
  const _AddButton({required this.onTap});

  @override
  State<_AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<_AddButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _hover ? 0.92 : 1.0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(_hover ? 0.16 : 0.08),
              border: Border.all(
                color: Colors.white.withOpacity(_hover ? 0.28 : 0.14),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF4A6CF7)
                      .withOpacity(_hover ? 0.35 : 0.0),
                  blurRadius: 18,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(
              Icons.add,
              size: 24,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
//  Кнопка-луна
// ============================================================

class _MoonButton extends StatefulWidget {
  final bool connected;
  final VoidCallback onTap;

  const _MoonButton({required this.connected, required this.onTap});

  @override
  State<_MoonButton> createState() => _MoonButtonState();
}

class _MoonButtonState extends State<_MoonButton> {
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
              'assets/lune.png',
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

// ============================================================
//  Селектор конфига
// ============================================================

class _ConfigSelector extends StatelessWidget {
  final List<ConfigItem> configs;
  final int? selectedId;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onDelete;

  const _ConfigSelector({
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
                    onSelect: () => onSelect(c.id),
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
                  widget.config.name.isEmpty
                      ? widget.config.peer
                      : widget.config.name,
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
