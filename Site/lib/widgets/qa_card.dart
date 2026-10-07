// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Карточка "вопрос — ответ": иконка слева, заголовок, содержимое.
// Используется для блоков "Как это работает?" и "Как развернуть сервер".

import 'package:flutter/material.dart';

import 'glass_card.dart';

class QaCard extends StatelessWidget {
  final String iconUrl;
  final String title;
  final Widget child;

  const QaCard({
    super.key,
    required this.iconUrl,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _IconOrFallback(url: iconUrl),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    );
  }
}

class _IconOrFallback extends StatelessWidget {
  final String url;

  const _IconOrFallback({required this.url});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF4A6CF7).withOpacity(0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF4A6CF7).withOpacity(0.35),
        ),
      ),
      padding: const EdgeInsets.all(8),
      child: Image.network(
        url,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const Icon(
          Icons.image_not_supported_outlined,
          size: 20,
          color: Colors.white54,
        ),
        loadingBuilder: (_, child, progress) {
          if (progress == null) return child;
          return const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white54,
              ),
            ),
          );
        },
      ),
    );
  }
}
