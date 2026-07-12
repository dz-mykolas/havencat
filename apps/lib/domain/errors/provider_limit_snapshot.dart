class ProviderLimitWindow {
  const ProviderLimitWindow({
    this.name,
    this.usedPercent,
    this.remaining,
    this.limit,
    this.window,
    this.resetsAt,
  });

  final String? name;
  final double? usedPercent;
  final num? remaining;
  final num? limit;
  final Duration? window;
  final DateTime? resetsAt;
}

class ProviderLimitSnapshot {
  const ProviderLimitSnapshot({
    required this.providerId,
    required this.capturedAt,
    required this.windows,
    this.accountId,
    this.reachedType,
  });

  final String providerId;
  final String? accountId;
  final DateTime capturedAt;
  final List<ProviderLimitWindow> windows;
  final String? reachedType;
}

abstract interface class UsageLimitsCapability {
  Future<ProviderLimitSnapshot?> getUsageLimits();
}
