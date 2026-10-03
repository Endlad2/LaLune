// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

class CoreInfo {
  final String localVersion;
  final String remoteVersion;
  final bool hasUpdate;

  const CoreInfo({
    this.localVersion = '',
    this.remoteVersion = '',
    this.hasUpdate = false,
  });

  factory CoreInfo.fromJson(Map<String, dynamic> j) => CoreInfo(
        localVersion: (j['local'] ?? '') as String,
        remoteVersion: (j['remote'] ?? '') as String,
        hasUpdate: (j['hasUpdate'] ?? false) as bool,
      );

  static const empty = CoreInfo();
}
