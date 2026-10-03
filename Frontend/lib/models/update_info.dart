// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

class UpdateInfo {
  final bool hasUpdate;
  final String remoteTag;
  final String localVersion;

  const UpdateInfo({
    this.hasUpdate = false,
    this.remoteTag = '',
    this.localVersion = '',
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> j) => UpdateInfo(
        hasUpdate: (j['hasUpdate'] ?? false) as bool,
        remoteTag: (j['remoteTag'] ?? '') as String,
        localVersion: (j['localVersion'] ?? '') as String,
      );

  static const empty = UpdateInfo();
}
