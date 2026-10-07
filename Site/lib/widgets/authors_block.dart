// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants.dart';
import 'glass_card.dart';

class AuthorsBlock extends StatelessWidget {
  const AuthorsBlock({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AuthorCard(
          name: 'Endlad7373',
          role: 'разработчик LaLune',
          github: Links.endladGh,
          githubLabel: 'github.com/Endlad2',
          telegram: Links.endladTg,
          telegramLabel: '@Endlad7373',
        ),
        const SizedBox(height: 14),
        _AuthorCard(
          name: 'amurcanov',
          role: 'разработчик CSQTT',
          github: Links.amurcanovGh,
          githubLabel: 'github.com/amurcanov',
          telegram: Links.amurcanovTg,
          telegramLabel: '@amurcanov_dev',
        ),
      ],
    );
  }
}

class _AuthorCard extends StatelessWidget {
  final String name;
  final String role;
  final String github;
  final String githubLabel;
  final String telegram;
  final String telegramLabel;

  const _AuthorCard({
    required this.name,
    required this.role,
    required this.github,
    required this.githubLabel,
    required this.telegram,
    required this.telegramLabel,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFF4A6CF7), Color(0xFFF7E84E)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF4A6CF7).withOpacity(0.35),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Center(
              child: Text(
                name.substring(0, 1).toUpperCase(),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                Text(
                  role,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Colors.white.withOpacity(0.55),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  children: [
                    _LinkChip(
                      icon: Icons.code,
                      label: githubLabel,
                      url: github,
                    ),
                    _LinkChip(
                      icon: Icons.send,
                      label: telegramLabel,
                      url: telegram,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String url;

  const _LinkChip({
    required this.icon,
    required this.label,
    required this.url,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        await launchUrl(Uri.parse(url),
            mode: LaunchMode.externalApplication);
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: Colors.white70),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white70,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
