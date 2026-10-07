// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Блок донатов: карточки с адресами и кнопками копирования.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants.dart';
import 'copy_button.dart';
import 'glass_card.dart';

class DonateBlock extends StatelessWidget {
  const DonateBlock({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DonateCard(
          title: 'amurcanov',
          subtitle: 'разработчик CSQTT',
          wallet: Wallets.gram,
          walletLabel: 'GRAM (TON)',
        ),
        const SizedBox(height: 16),
        _DonateCard(
          title: 'amurcanov',
          subtitle: 'разработчик CSQTT',
          wallet: Wallets.usdtTon,
          walletLabel: 'USDT (TON)',
          hideTitle: true,
        ),
        const SizedBox(height: 16),
        _DonateCard(
          title: 'amurcanov',
          subtitle: 'разработчик CSQTT',
          wallet: Wallets.usdtTrc,
          walletLabel: 'USDT (TRC20)',
          hideTitle: true,
        ),
        const SizedBox(height: 16),
        _DonateCard(
          title: 'Endlad7373',
          subtitle: 'разработчик LaLune',
          link: Links.yoomoney,
          linkLabel: 'yoomoney.ru/to/4100119505530465/100',
          wallet: Wallets.cardRaw,
          walletLabel: 'Карта (Сбер)',
          walletDisplay: Wallets.card,
          titleLink: Links.endladGh,
        ),
      ],
    );
  }
}

class _DonateCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? wallet;
  final String? walletLabel;
  final String? walletDisplay;
  final String? link;
  final String? linkLabel;
  final String? titleLink;
  final bool hideTitle;

  const _DonateCard({
    required this.title,
    required this.subtitle,
    this.wallet,
    this.walletLabel,
    this.walletDisplay,
    this.link,
    this.linkLabel,
    this.titleLink,
    this.hideTitle = false,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!hideTitle)
            Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 8),
                if (titleLink != null)
                  _IconLink(url: titleLink!, icon: Icons.open_in_new),
                const SizedBox(width: 8),
                Text(
                  '— $subtitle',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withOpacity(0.55),
                  ),
                ),
              ],
            ),
          if (!hideTitle) const SizedBox(height: 14),

          if (walletLabel != null) ...[
            Text(
              walletLabel!,
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w700,
                color: Colors.white.withOpacity(0.45),
              ),
            ),
            const SizedBox(height: 8),
          ],

          if (wallet != null)
            _WalletRow(
              value: wallet!,
              display: walletDisplay ?? wallet!,
            ),

          if (link != null) ...[
            const SizedBox(height: 12),
            InkWell(
              onTap: () async {
                final uri = Uri.parse(link!);
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF4A6CF7).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFF4A6CF7).withOpacity(0.4),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.link,
                        size: 14, color: Color(0xFF4A6CF7)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        linkLabel ?? link!,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF9AB0FF),
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.open_in_new,
                        size: 14, color: Color(0xFF9AB0FF)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _WalletRow extends StatelessWidget {
  final String value;
  final String display;

  const _WalletRow({required this.value, required this.display});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              display,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: Colors.white,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 12),
          CopyButton(value: value),
        ],
      ),
    );
  }
}

class _IconLink extends StatelessWidget {
  final String url;
  final IconData icon;

  const _IconLink({required this.url, required this.icon});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        await launchUrl(Uri.parse(url),
            mode: LaunchMode.externalApplication);
      },
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 14, color: Colors.white54),
      ),
    );
  }
}
