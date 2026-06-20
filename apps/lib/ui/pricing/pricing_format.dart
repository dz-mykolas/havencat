/// Small, dependency-free formatting helpers for the pricing UI.
///
/// All prices from models.dev are USD per **million** tokens.
library;

/// Formats a USD-per-million-token figure, e.g. `$3.00`, `$0.15`, `Free`.
String formatPricePerMillion(double? value) {
  if (value == null) return '—';
  if (value == 0) return 'Free';
  // Sub-dollar prices read better with more precision (e.g. $0.075).
  if (value < 1) return '\$${_trim(value, 3)}';
  return '\$${_trim(value, 2)}';
}

/// Compact token count, e.g. `1M`, `200K`, `8.2K`, `512`.
String formatTokens(int? tokens) {
  if (tokens == null || tokens <= 0) return '—';
  if (tokens >= 1000000) {
    final double m = tokens / 1000000;
    return '${_trim(m, m % 1 == 0 ? 0 : 1)}M';
  }
  if (tokens >= 1000) {
    final double k = tokens / 1000;
    return '${_trim(k, k % 1 == 0 ? 0 : 1)}K';
  }
  return '$tokens';
}

/// Coarse "time ago" label for the cache timestamp, e.g. `just now`,
/// `5m ago`, `3h ago`, `2d ago`.
String formatRelative(DateTime time) {
  final Duration d = DateTime.now().difference(time);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

String _trim(double value, int decimals) {
  final String s = value.toStringAsFixed(decimals);
  if (!s.contains('.')) return s;
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}
