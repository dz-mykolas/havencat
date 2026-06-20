import 'dart:async';

import '../../../domain/models/oauth_tokens.dart';
import 'chatgpt_oauth_flow.dart';
import 'secret_store.dart';

/// Owns the lifecycle of a ChatGPT subscription account's OAuth tokens.
///
/// Why this exists: a fully-local app has no backend to refresh tokens, so the
/// client must do it. Access tokens are short-lived; on every use we check
/// expiry and, if needed, exchange the rotating refresh token for a fresh
/// bundle and persist it back to secure storage. This is what makes a login
/// survive an app restart / browser refresh: the refresh token is durable, and
/// the access token is transparently re-minted on demand.
///
/// Concurrency: if several requests hit an expired token at once, they share a
/// single in-flight refresh (single-flight) so we don't fire N refreshes and
/// invalidate each other's rotated refresh tokens.
class ChatGptTokenService {
  ChatGptTokenService({
    required SecretStore secretStore,
    required ChatGptOAuthFlow oauthFlow,
  }) : _secrets = secretStore,
       _oauth = oauthFlow;

  final SecretStore _secrets;
  final ChatGptOAuthFlow _oauth;

  /// In-flight refreshes keyed by account id (single-flight).
  final Map<String, Future<String?>> _refreshing = <String, Future<String?>>{};

  /// Persist a freshly-obtained token bundle for [accountId].
  Future<void> storeTokens(String accountId, OAuthTokens tokens) {
    return _secrets.write(accountId, tokens.encode());
  }

  /// Returns a usable access token for [accountId], refreshing first if the
  /// stored one is expired (or about to). Returns null if the account has no
  /// stored tokens at all (i.e. signed out).
  Future<String?> validAccessToken(String accountId) async {
    final OAuthTokens? tokens = OAuthTokens.tryDecode(
      await _secrets.read(accountId),
    );
    if (tokens == null) return null;

    if (!tokens.isExpired()) return tokens.accessToken;

    // Expired (or near it). Refresh if we can; otherwise hand back the stale
    // token and let the API surface a 401 → "sign in again".
    if (!tokens.canRefresh) return tokens.accessToken;

    return _refreshing
        .putIfAbsent(accountId, () => _refresh(accountId, tokens.refreshToken!))
        .whenComplete(() => _refreshing.remove(accountId));
  }

  Future<String?> _refresh(String accountId, String refreshToken) async {
    try {
      final ChatGptAuthResult result = await _oauth.refreshToken(refreshToken);
      final OAuthTokens refreshed = OAuthTokens(
        accessToken: result.accessToken,
        // Keep the previous refresh token if the server didn't rotate one.
        refreshToken: result.refreshToken ?? refreshToken,
        expiresAt: result.expiresAt,
      );
      await storeTokens(accountId, refreshed);
      return refreshed.accessToken;
    } on ChatGptAuthException {
      // Refresh failed (revoked / expired refresh token). Surface as "no valid
      // token" so the caller prompts a fresh sign-in rather than retrying.
      return null;
    }
  }

  /// Best-effort server-side revoke of the stored tokens, used on sign-out.
  /// The caller is still responsible for deleting the secret locally.
  Future<void> revoke(String accountId) async {
    final OAuthTokens? tokens = OAuthTokens.tryDecode(
      await _secrets.read(accountId),
    );
    if (tokens == null) return;
    if (tokens.refreshToken != null) {
      await _oauth.revoke(tokens.refreshToken!);
    }
    await _oauth.revoke(tokens.accessToken);
  }
}
