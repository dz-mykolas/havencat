import 'dart:convert';

/// The secret material for an OAuth (subscription) account: the access token,
/// the rotating refresh token, and when the access token expires.
///
/// This is the *secret* half of a subscription account — it is always written
/// to secure storage via `SecretStore`, never to the plaintext account
/// metadata in [ProviderAccount.config]. The bundle is serialized to a single
/// JSON string so one secure-storage entry per account holds everything the
/// token lifecycle needs.
class OAuthTokens {
  const OAuthTokens({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
  });

  final String accessToken;

  /// Rotating refresh token. May be null if the provider didn't issue one.
  final String? refreshToken;

  /// When [accessToken] stops being accepted. Null means "unknown" — we then
  /// treat the token as usable until the server rejects it.
  final DateTime? expiresAt;

  /// True when the access token is expired or within [leeway] of expiring, so
  /// callers refresh slightly early rather than racing the exact expiry.
  bool isExpired({Duration leeway = const Duration(seconds: 60)}) {
    final DateTime? exp = expiresAt;
    if (exp == null) return false;
    return DateTime.now().isAfter(exp.subtract(leeway));
  }

  /// True when we hold a refresh token and can therefore mint a new access
  /// token without forcing the user to sign in again.
  bool get canRefresh => refreshToken != null && refreshToken!.isNotEmpty;

  OAuthTokens copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) {
    return OAuthTokens(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'accessToken': accessToken,
    if (refreshToken != null) 'refreshToken': refreshToken,
    if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
  };

  factory OAuthTokens.fromJson(Map<String, Object?> json) {
    final Object? exp = json['expiresAt'];
    return OAuthTokens(
      accessToken: json['accessToken'] as String,
      refreshToken: json['refreshToken'] as String?,
      expiresAt: exp is String ? DateTime.tryParse(exp) : null,
    );
  }

  /// Encode for storage in `SecretStore` (one JSON string per account).
  String encode() => jsonEncode(toJson());

  /// Decode a stored bundle. Returns null if [raw] isn't a valid bundle —
  /// e.g. legacy accounts that stored a bare access-token string.
  static OAuthTokens? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? parsed = jsonDecode(raw);
      if (parsed is Map<String, Object?> && parsed['accessToken'] is String) {
        return OAuthTokens.fromJson(parsed);
      }
    } on FormatException {
      // Not JSON — fall through to the bare-token compatibility path.
    }
    // Backwards compatibility: a previously stored bare access token.
    return OAuthTokens(accessToken: raw);
  }
}
