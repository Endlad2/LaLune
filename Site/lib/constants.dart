// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Константы: ссылки на ассеты (raw GitHub), URL'ы, адреса кошельков.

class Links {
  Links._();

  // ---------- GitHub raw (Assets/) ----------
  static const String _rawBase =
      'https://raw.githubusercontent.com/Endlad2/LaLune/refs/heads/main/Assets';

  static const String background = '$_rawBase/background.png';
  static const String lune       = '$_rawBase/lune.png';
  static const String connect    = '$_rawBase/connect.png';
  static const String settings   = '$_rawBase/settings.png';
  static const String info       = '$_rawBase/info.png';
  static const String logs       = '$_rawBase/logs.png';
  static const String maxQr      = '$_rawBase/max_qr.jpg';
  static const String icon       = '$_rawBase/icon.png';

  // ---------- GitHub ----------
  static const String repo       = 'https://github.com/Endlad2/LaLune';
  static const String releases   = 'https://github.com/Endlad2/LaLune/releases/latest';
  static const String endladGh   = 'https://github.com/Endlad2';
  static const String amurcanovGh = 'https://github.com/amurcanov';
  static const String csqttCore  = 'https://github.com/Endlad2/csqtt-core';

  // ---------- GitHub avatars ----------
  static const String endladAvatar =
      'https://avatars.githubusercontent.com/u/185694518?s=70&v=4';
  static const String amurcanovAvatar =
      'https://avatars.githubusercontent.com/u/222097921?s=70&v=4';

  // ---------- Telegram ----------
  static const String communityTg = 'https://t.me/wdttcommunity';
  static const String endladTg    = 'https://t.me/Endlad7373';
  static const String amurcanovTg = 'https://t.me/amurcanov_dev';

  // ---------- Донаты ----------
  static const String yoomoney =
      'https://yoomoney.ru/to/4100119505530465/100';

  // ---------- Скачать ----------
  static const String latestVersion    = '0.6.0';
  static const String yandexDisk       = 'https://disk.yandex.ru/d/e3_zJQfHn7xI_Q';

  // ---------- Счётчик ----------
  static const String counter =
      'https://count.owenewans.org/Endlad2/LaLune?theme=moebooru&notitle';

  // ---------- Протоколы ----------
  static const List<ProtocolInfo> protocols = [
    ProtocolInfo(
      name: 'CSQTT',
      subtitle: 'VK Calls + TURN',
      description:
          'Основной протокол LaLune. Пробрасывает трафик через VK Звонки и TURN-серверы.',
      repo: 'https://github.com/Endlad2/csqtt-core',
    ),
    ProtocolInfo(
      name: 'FreeTurn',
      subtitle: 'Free TURN relay',
      description: 'Лёгкий TURN-прокси. Хорошо работает как резервный канал.',
      repo: 'https://github.com/Endlad2/free-turn-proxy-core',
    ),
    ProtocolInfo(
      name: 'OlcRTC',
      subtitle: 'WebRTC relay',
      description: 'WebRTC-туннель, маскируется под обычный peer-to-peer звонок.',
      repo: 'https://github.com/Endlad2/olcrtc-core',
    ),
    ProtocolInfo(
      name: 'OpenFlux',
      subtitle: 'Docs + MAX',
      description:
          'Пробрасывает трафик через облачные документы и мессенджер MAX.',
      repo: 'https://github.com/Endlad2/OpenFlux-core',
    ),
    ProtocolInfo(
      name: 'ToTS',
      subtitle: 'ToTS relay',
      description: 'Экспериментальный протокол сообщества.',
      repo: 'https://github.com/Endlad2/ToTS',
    ),
  ];
}

class ProtocolInfo {
  final String name;
  final String subtitle;
  final String description;
  final String repo;

  const ProtocolInfo({
    required this.name,
    required this.subtitle,
    required this.description,
    required this.repo,
  });
}

class Wallets {
  Wallets._();

  static const String gram    = 'UQCsHSj_Bev5AG3vCz-84TQC7BSWjNdNd0jP9M2gWUEmbyD7';
  static const String usdtTon = 'UQCsHSj_Bev5AG3vCz-84TQC7BSWjNdNd0jP9M2gWUEmbyD7';
  static const String usdtTrc = 'TD1oiQiHmjqsRDPxfUjUbSwxEmcr4k7Lob';
  static const String card    = '2202 2084 5363 0882';
  static const String cardRaw = '2202208453630882';
}
