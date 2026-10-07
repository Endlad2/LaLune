// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Главная страница: hero, как это работает, развёртывание, скачать,
// поддержка, донаты, авторы, ограничения интернета.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants.dart';
import '../theme/app_theme.dart';
import '../widgets/authors_block.dart';
import '../widgets/donate_block.dart';
import '../widgets/download_section.dart';
import '../widgets/glass_card.dart';
import '../widgets/glass_scaffold.dart';
import '../widgets/qa_card.dart';
import '../widgets/section_title.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  late final AnimationController _heroCtrl;
  late final Animation<double> _heroFade;
  late final Animation<Offset> _heroSlide;

  double _scrollOffset = 0;

  @override
  void initState() {
    super.initState();

    _heroCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _heroFade = CurvedAnimation(
      parent: _heroCtrl,
      curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
    );
    _heroSlide = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _heroCtrl,
      curve: const Interval(0.0, 1.0, curve: Curves.easeOutCubic),
    ));
    _heroCtrl.forward();

    _scroll.addListener(() {
      setState(() => _scrollOffset = _scroll.offset);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _heroCtrl.dispose();
    super.dispose();
  }

  Future<void> _open(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      child: Stack(
        children: [
          // Параллакс-фон поверх основного
          Positioned.fill(
            child: IgnorePointer(
              child: Transform.translate(
                offset: Offset(0, _scrollOffset * 0.25),
                child: Image.network(
                  Links.lune,
                  fit: BoxFit.none,
                  alignment: const Alignment(2.0, -1.2),
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  opacity: const AlwaysStoppedAnimation(0.06),
                ),
              ),
            ),
          ),

          // Основной контент
          SingleChildScrollView(
            controller: _scroll,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 24,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 60),
                      _buildHero(),
                      const SizedBox(height: 100),
                      _buildHowItWorks(),
                      const SizedBox(height: 32),
                      _buildDeploy(),
                      const SizedBox(height: 32),
                      _buildDownload(),
                      const SizedBox(height: 32),
                      _buildSupport(),
                      const SizedBox(height: 48),
                      const SectionTitle(
                        text: 'Донаты',
                        subtitle:
                            'Если хочешь поддержать разработчиков — вот реквизиты.',
                      ),
                      const SizedBox(height: 20),
                      const DonateBlock(),
                      const SizedBox(height: 48),
                      const SectionTitle(
                        text: 'Авторы',
                        subtitle: 'Те, кто делает LaLune и CSQTT.',
                      ),
                      const SizedBox(height: 20),
                      const AuthorsBlock(),
                      const SizedBox(height: 48),
                      _buildMaxChannel(),
                      const SizedBox(height: 48),
                      _buildFooter(),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  //  HERO
  // ============================================================

  Widget _buildHero() {
    return FadeTransition(
      opacity: _heroFade,
      child: SlideTransition(
        position: _heroSlide,
        child: Column(
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.6, end: 1.0),
              duration: const Duration(milliseconds: 1200),
              curve: Curves.easeOutBack,
              builder: (context, v, child) {
                return Transform.scale(scale: v, child: child);
              },
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: kAccentYellow.withOpacity(0.35),
                      blurRadius: 60,
                      spreadRadius: 8,
                    ),
                  ],
                ),
                child: Image.network(
                  Links.lune,
                  width: 150,
                  height: 150,
                  errorBuilder: (_, __, ___) => Container(
                    width: 150,
                    height: 150,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: kSurface,
                    ),
                    child: const Center(
                      child: Text('🌙', style: TextStyle(fontSize: 72)),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),

            ShaderMask(
              shaderCallback: (rect) => const LinearGradient(
                colors: [kAccentYellow, Colors.white],
              ).createShader(rect),
              child: const Text(
                'LaLune',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 64,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: -2,
                  height: 1.1,
                ),
              ),
            ),
            const SizedBox(height: 16),

            Text(
              'Кроссплатформенный клиент VPN\n'
              'для обхода белых списков',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                height: 1.5,
                color: Colors.white.withOpacity(0.75),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 36),

            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                _HeroButton(
                  label: 'Как это работает?',
                  icon: Icons.help_outline,
                  onTap: () => _scrollTo(0),
                ),
                _HeroButton(
                  label: 'Развернуть свой сервер',
                  icon: Icons.cloud_upload_outlined,
                  onTap: () => _scrollTo(1),
                ),
                _HeroButton(
                  label: 'Скачать',
                  icon: Icons.download,
                  primary: true,
                  onTap: () => _open(Links.releases),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _scrollTo(int sectionIndex) {
    const positions = [900.0, 1700.0];
    if (sectionIndex < positions.length) {
      _scroll.animateTo(
        positions[sectionIndex],
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  // ============================================================
  //  КАК ЭТО РАБОТАЕТ
  // ============================================================

  Widget _buildHowItWorks() {
    return QaCard(
      iconUrl: Links.logs,
      title: 'Как это работает?',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ты подключаешься к посреднику — сервису, который в твоей '
            'сети не блокируется: VK Звонки, Яндекс Документы, '
            'Mail Docs, OneME и другие. Трафик маскируется под обычный '
            'обмен данными внутри этого сервиса.',
            style: TextStyle(
              fontSize: 15,
              height: 1.6,
              color: Colors.white.withOpacity(0.85),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Посредник уже сам устанавливает соединение с твоим '
            'сервером (или с публичным сервером сообщества), и весь '
            'трафик идёт по цепочке:',
            style: TextStyle(
              fontSize: 15,
              height: 1.6,
              color: Colors.white.withOpacity(0.85),
            ),
          ),
          const SizedBox(height: 22),
          const _FlowDiagram(),
          const SizedBox(height: 18),
          Text(
            'Для DPI это выглядит как обычный звонок или загрузка '
            'документа — заблокировать нельзя, не сломав сам '
            'сервис-посредник.',
            style: TextStyle(
              fontSize: 13.5,
              height: 1.6,
              color: Colors.white.withOpacity(0.55),
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  //  РАЗВЕРНУТЬ СЕРВЕР
  // ============================================================

  Widget _buildDeploy() {
    return QaCard(
      iconUrl: Links.info,
      title: 'Что если я хочу развернуть свой сервер?',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Способ развёртывания зависит от протокола. Каждый протокол '
            '— это отдельный серверный бинарь, который ставится на VPS '
            'по SSH.',
            style: TextStyle(
              fontSize: 15,
              height: 1.6,
              color: Colors.white.withOpacity(0.85),
            ),
          ),
          const SizedBox(height: 20),
          ...Links.protocols.map((p) => _ProtocolCard(info: p)),
          const SizedBox(height: 16),
          Text(
            'Установка — через DeployManager внутри клиента '
            '(вкладка «Деплой») или вручную по SSH. Подробности — '
            'в README каждого репозитория.',
            style: TextStyle(
              fontSize: 13.5,
              height: 1.6,
              color: Colors.white.withOpacity(0.55),
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  //  СКАЧАТЬ
  // ============================================================

  Widget _buildDownload() {
    return const DownloadSection();
  }

  // ============================================================
  //  ПОДДЕРЖКА
  // ============================================================

  Widget _buildSupport() {
    return GlassCard(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                Links.counter,
                height: 32,
                errorBuilder: (_, __, ___) => const SizedBox(height: 32),
              ),
            ),
          ),
          const SizedBox(height: 24),

          Text(
            'Мне будет очень приятно, если ты поддержишь проект звездой '
            'на GitHub ⭐ или донатом 💛.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              height: 1.55,
              color: Colors.white.withOpacity(0.9),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Если мы добьёмся 128 звёзд — я запущу полностью бесплатный '
            'и бесперебойный VPN для обхода белых списков.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              height: 1.55,
              color: kAccentYellow,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                _HeroButton(
                  label: 'Поставить звезду',
                  icon: Icons.star_outline,
                  primary: true,
                  onTap: () => _open(Links.repo),
                ),
                _HeroButton(
                  label: 'Донат',
                  icon: Icons.favorite_outline,
                  onTap: () {
                    _scroll.animateTo(
                      _scroll.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 900),
                      curve: Curves.easeInOutCubic,
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  //  MAX-КАНАЛ
  // ============================================================

  Widget _buildMaxChannel() {
    return GlassCard(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.qr_code_2, size: 20, color: kAccentYellow),
              SizedBox(width: 10),
              Text(
                'Ограничения интернета',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Если ты находишься в белых списках или подобных '
            'ограничениях интернета, при которых недоступен сайт '
            'GitHub, а обновиться надо — используй наш канал в MAX. '
            'Туда выходят все апдейты.',
            style: TextStyle(
              fontSize: 14.5,
              height: 1.6,
              color: Colors.white.withOpacity(0.85),
            ),
          ),
          const SizedBox(height: 18),
          Center(
            child: _HeroButton(
              label: 'Показать QR для канала MAX',
              icon: Icons.qr_code_2,
              onTap: _showMaxQr,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showMaxQr() async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.7),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: GlassCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Канал LaLune в MAX',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close,
                          size: 20, color: Colors.white70),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    Links.maxQr,
                    width: 360,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Container(
                      width: 360,
                      height: 360,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: Colors.white.withOpacity(0.15)),
                      ),
                      child: const Center(
                        child: Text(
                          'QR не загрузился',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Отсканируй QR-код, чтобы подписаться на канал.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withOpacity(0.65),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  //  FOOTER
  // ============================================================

  Widget _buildFooter() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: const Color(0xFF4A6CF7).withOpacity(0.10),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: const Color(0xFF4A6CF7).withOpacity(0.35),
            ),
          ),
          child: Column(
            children: [
              const Icon(Icons.groups,
                  size: 32, color: Color(0xFF9AB0FF)),
              const SizedBox(height: 12),
              const Text(
                'Присоединяйтесь к нашему сообществу в Telegram',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 14),
              _HeroButton(
                label: '@wdttcommunity',
                icon: Icons.send,
                primary: true,
                onTap: () => _open(Links.communityTg),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Text(
          'PolyForm Noncommercial License 1.0.0 · 2026',
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withOpacity(0.4),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Сделано с 💛 для свободного интернета',
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withOpacity(0.4),
          ),
        ),
      ],
    );
  }
}

// ============================================================
//  ВСПОМОГАТЕЛЬНЫЕ ВИДЖЕТЫ
// ============================================================

class _HeroButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool primary;

  const _HeroButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.primary = false,
  });

  @override
  State<_HeroButton> createState() => _HeroButtonState();
}

class _HeroButtonState extends State<_HeroButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.primary
        ? kAccent
        : (_hover
            ? Colors.white.withOpacity(0.14)
            : Colors.white.withOpacity(0.06));
    final border = widget.primary
        ? kAccent
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
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
            boxShadow: _hover || widget.primary
                ? [
                    BoxShadow(
                      color: kAccent.withOpacity(_hover ? 0.35 : 0.2),
                      blurRadius: 20,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 16, color: Colors.white),
              const SizedBox(width: 10),
              Text(
                widget.label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FlowDiagram extends StatelessWidget {
  const _FlowDiagram();

  @override
  Widget build(BuildContext context) {
    final nodes = [
      ('📱', 'Ты'),
      ('💬', 'Посредник\nVK / Яндекс'),
      ('🖥️', 'Сервер'),
      ('🌐', 'Интернет'),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 560;

        final children = <Widget>[];
        for (var i = 0; i < nodes.length; i++) {
          final (emoji, label) = nodes[i];
          children.add(_FlowNode(emoji: emoji, label: label));
          if (i < nodes.length - 1) {
            children.add(Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isNarrow ? 4 : 8,
                vertical: isNarrow ? 4 : 0,
              ),
              child: Icon(
                isNarrow ? Icons.arrow_downward : Icons.arrow_forward,
                size: 16,
                color: Colors.white.withOpacity(0.4),
              ),
            ));
          }
        }

        return isNarrow
            ? Column(children: children)
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: children,
              );
      },
    );
  }
}

class _FlowNode extends StatelessWidget {
  final String emoji;
  final String label;

  const _FlowNode({required this.emoji, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 22)),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProtocolCard extends StatefulWidget {
  final ProtocolInfo info;

  const _ProtocolCard({required this.info});

  @override
  State<_ProtocolCard> createState() => _ProtocolCardState();
}

class _ProtocolCardState extends State<_ProtocolCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () async {
          await launchUrl(Uri.parse(widget.info.repo),
              mode: LaunchMode.externalApplication);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _hover
                ? const Color(0xFF4A6CF7).withOpacity(0.10)
                : Colors.white.withOpacity(0.03),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _hover
                  ? const Color(0xFF4A6CF7).withOpacity(0.5)
                  : Colors.white.withOpacity(0.08),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF4A6CF7).withOpacity(0.18),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      widget.info.name,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF9AB0FF),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.info.subtitle,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward,
                    size: 16,
                    color: Colors.white.withOpacity(_hover ? 0.9 : 0.4),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                widget.info.description,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: Colors.white.withOpacity(0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
