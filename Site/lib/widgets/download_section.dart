// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Секция «Скачать»: кнопка GitHub Releases, кнопка Яндекс.Диск,
// примечание про канал в MAX.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants.dart';
import 'glass_card.dart';

class DownloadSection extends StatelessWidget {
  const DownloadSection({super.key});

  Future<void> _open(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Заголовок
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF4A6CF7).withOpacity(0.14),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFF4A6CF7).withOpacity(0.35),
                  ),
                ),
                child: const Icon(
                  Icons.download_rounded,
                  color: Color(0xFF9AB0FF),
                  size: 22,
                ),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Text(
                  'Скачать LaLune',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Последняя версия: ${Links.latestVersion}',
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withOpacity(0.65),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 22),

          // Кнопки
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 560;
              final buttons = [
                _DownloadButton(
                  icon: Icons.code,
                  title: 'GitHub Releases',
                  subtitle: 'Актуальный релиз, все платформы',
                  onTap: () => _open(Links.releases),
                  primary: true,
                ),
                _DownloadButton(
                  icon: Icons.cloud_download_outlined,
                  title: 'Яндекс.Диск',
                  subtitle: 'Зеркало релиза ${Links.latestVersion}',
                  onTap: () => _open(Links.yandexDisk),
                ),
              ];

              if (isNarrow) {
                return Column(
                  children: [
                    buttons[0],
                    const SizedBox(height: 12),
                    buttons[1],
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: buttons[0]),
                  const SizedBox(width: 12),
                  Expanded(child: buttons[1]),
                ],
              );
            },
          ),

          const SizedBox(height: 20),

          // Примечание про MAX
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF7E84E).withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFF7E84E).withOpacity(0.35),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.tips_and_updates_outlined,
                  size: 16,
                  color: Color(0xFFF7E84E),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Если GitHub недоступен (белые списки, ограничения) — '
                    'все релизы публикуются в нашем канале MAX. '
                    'Открой QR-код в блоке «Ограничения интернета» ниже.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: Colors.white.withOpacity(0.85),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadButton extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;

  const _DownloadButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  @override
  State<_DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<_DownloadButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.primary
        ? const Color(0xFF4A6CF7)
        : (_hover
            ? Colors.white.withOpacity(0.10)
            : Colors.white.withOpacity(0.04));
    final border = widget.primary
        ? const Color(0xFF4A6CF7)
        : Colors.white.withOpacity(_hover ? 0.3 : 0.15);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
            boxShadow: _hover || widget.primary
                ? [
                    BoxShadow(
                      color: const Color(0xFF4A6CF7)
                          .withOpacity(_hover ? 0.35 : 0.2),
                      blurRadius: 20,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 22, color: Colors.white),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withOpacity(0.7),
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward,
                size: 16,
                color: Colors.white.withOpacity(_hover ? 0.9 : 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
