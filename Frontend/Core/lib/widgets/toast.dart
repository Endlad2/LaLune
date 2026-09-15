import 'package:flutter/material.dart';

/// Глобальный оверлей для всплывающих сообщений снизу.
///
/// Использование:
///   Toast.show(context, 'Текст сообщения');
///   Toast.show(context, 'Не удалось подключиться', isError: true);
class Toast {
  static OverlayEntry? _current;
  static _ToastState? _currentState;

  static void show(
    BuildContext context,
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 3),
  }) {
    // Если уже что-то висит — убиваем старое
    _current?.remove();
    _current = null;
    _currentState = null;

    final overlay = Overlay.of(context);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastWidget(
        message: message,
        isError: isError,
        duration: duration,
        onDismiss: () {
          if (_current == entry) {
            entry.remove();
            _current = null;
            _currentState = null;
          }
        },
        onReady: (state) => _currentState = state,
      ),
    );

    _current = entry;
    overlay.insert(entry);
  }
}

class _ToastWidget extends StatefulWidget {
  final String message;
  final bool isError;
  final Duration duration;
  final VoidCallback onDismiss;
  final ValueChanged<_ToastState> onReady;

  const _ToastWidget({
    required this.message,
    required this.isError,
    required this.duration,
    required this.onDismiss,
    required this.onReady,
  });

  @override
  State<_ToastWidget> createState() => _ToastState();
}

class _ToastState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );

    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.35),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

    widget.onReady(this);

    _ctrl.forward();
    _scheduleDismiss();
  }

  void _scheduleDismiss() {
    Future.delayed(widget.duration, () async {
      if (!mounted) return;
      await _ctrl.reverse();
      if (!mounted) return;
      widget.onDismiss();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.isError
        ? const Color(0xFF3A2A0A).withOpacity(0.94)
        : const Color(0xFF3A3000).withOpacity(0.94);
    final border = widget.isError
        ? const Color(0xFFFF8A8A).withOpacity(0.55)
        : const Color(0xFFF7E84E).withOpacity(0.55);
    final textColor = widget.isError
        ? const Color(0xFFFFE0E0)
        : const Color(0xFFFFF7D6);

    return Positioned(
      left: 0,
      right: 0,
      bottom: 96,
      child: IgnorePointer(
        child: SlideTransition(
          position: _slide,
          child: FadeTransition(
            opacity: _fade,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: border, width: 1),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.35),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.isError
                            ? Icons.error_outline
                            : Icons.info_outline,
                        size: 18,
                        color: widget.isError
                            ? const Color(0xFFFF8A8A)
                            : const Color(0xFFF7E84E),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          widget.message,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
