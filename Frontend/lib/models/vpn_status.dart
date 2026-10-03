// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

class VpnStatus {
  final String state; // connected | disconnected | connecting | disconnecting | error
  final bool connected;
  final int uptimeSec;
  final int configId;
  final String message;

  const VpnStatus({
    this.state = 'disconnected',
    this.connected = false,
    this.uptimeSec = 0,
    this.configId = 0,
    this.message = '',
  });

  factory VpnStatus.fromJson(Map<String, dynamic> j) => VpnStatus(
        state: (j['state'] ?? 'disconnected') as String,
        connected: (j['connected'] ?? false) as bool,
        uptimeSec: ((j['uptimeSec'] ?? 0) as num).toInt(),
        configId: ((j['configId'] ?? 0) as num).toInt(),
        message: (j['message'] ?? '') as String,
      );

  static const empty = VpnStatus();
}
