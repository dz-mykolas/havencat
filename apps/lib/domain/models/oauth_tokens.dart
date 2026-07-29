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
    DateTime? expiresAt;
    if (exp != null) {
      if (exp is! String) {
        throw const FormatException('OAuth token expiry is invalid.');
      }
      expiresAt = DateTime.tryParse(exp);
      if (expiresAt == null) {
        throw const FormatException('OAuth token expiry is invalid.');
      }
    }
    final String accessToken = json['accessToken'] as String;
    if (accessToken.isEmpty) {
      throw const FormatException('OAuth access token is empty.');
    }
    return OAuthTokens(
      accessToken: accessToken,
      refreshToken: json['refreshToken'] as String?,
      expiresAt: expiresAt,
    );
  }

  /// Encode for storage in `SecretStore` (one JSON string per account).
  String encode() => jsonEncode(toJson());

  /// Decodes a stored bundle. Null means no bundle is stored; malformed
  /// persisted data throws instead of being interpreted as a token.
  static OAuthTokens? decode(String? raw) {
    if (raw == null) return null;
    if (raw.isEmpty) {
      throw const FormatException('Stored OAuth token bundle is empty.');
    }
    final Object? parsed = jsonDecode(raw);
    if (parsed is! Map) {
      throw const FormatException(
        'Stored OAuth token bundle is not an object.',
      );
    }
    return OAuthTokens.fromJson(Map<String, Object?>.from(parsed));
  }
}
