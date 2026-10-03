// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

class VkTokenState {
  final bool hasToken;
  final bool fetching;
  final int progress;
  final String message;

  const VkTokenState({
    this.hasToken = false,
    this.fetching = false,
    this.progress = 0,
    this.message = '',
  });

  factory VkTokenState.fromJson(Map<String, dynamic> j) => VkTokenState(
        hasToken: (j['hasToken'] ?? false) as bool,
        fetching: (j['fetching'] ?? false) as bool,
        progress: ((j['progress'] ?? 0) as num).toInt(),
        message: (j['message'] ?? '') as String,
      );

  static const empty = VkTokenState();
}
