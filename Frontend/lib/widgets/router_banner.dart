// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Глобальный зелёный баннер «Подключено к роутеру X».
// Показывается пока activeRouter != null, исчезает при disconnect().
//
// Клик по баннеру — отключиться (с подтверждением).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/router_notifier.dart';
import 'confirm_dialog.dart';

class RouterBanner extends ConsumerWidget {
  const RouterBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(routerProvider);
    final active = st.activeRouter;
    if (active == null) return const SizedBox.shrink();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () async {
          final ok = await showConfirmDialog(
            context,
            title: 'Отключиться от роутера?',
            message:
                'API вернётся на 127.0.0.1. Процессы на роутере НЕ будут '
                'остановлены — они продолжат работу.',
            confirmLabel: 'Отключить',
          );
          if (ok == true) {
            await ref.read(routerProvider.notifier).disconnect();
          }
        },
        child: Container(
          width: double.infinity,
          color: const Color(0xFF2E7D32),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
          child: Row(
            children: [
              const Icon(Icons.router, size: 16, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Подключено к роутеру ${active.displayName}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(Icons.close, size: 14, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}
