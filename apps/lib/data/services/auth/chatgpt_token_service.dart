import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:uuid/uuid.dart';

import '../../../domain/models/oauth_tokens.dart';
import '../../../src/rust/api/conversations.dart' as rust;
import '../storage/platform_io.dart'
    if (dart.library.html) '../storage/platform_web.dart'
    as platform;
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
/// invalidate each other's rotated refresh tokens. Across Flutter engines the
/// SQLite oauth_refresh_leases table serializes refresh ownership.
class ChatGptTokenService {
  ChatGptTokenService({
    required SecretStore secretStore,
    required ChatGptOAuthFlow oauthFlow,
    String? refreshOwnerId,
    this.crossProcessLeases = false,
  }) : _secrets = secretStore,
       _oauth = oauthFlow,
       _refreshOwnerId = refreshOwnerId ?? 'ui-${const Uuid().v4()}';

  final SecretStore _secrets;
  final ChatGptOAuthFlow _oauth;
  final String _refreshOwnerId;
  final bool crossProcessLeases;

  /// In-flight refreshes keyed by account id (single-flight).
  final Map<String, Future<String?>> _refreshing = <String, Future<String?>>{};

  static PlatformInt64 _ms(int value) =>
      (platform.isWeb ? BigInt.from(value) : value) as PlatformInt64;

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

    if (!tokens.canRefresh) return null;

    return _refreshing
        .putIfAbsent(accountId, () => _refresh(accountId, tokens.refreshToken!))
        .whenComplete(() => _refreshing.remove(accountId));
  }

  Future<String?> _refresh(String accountId, String refreshToken) async {
    final bool leased = await _acquireRefreshLease(accountId);
    if (!leased) {
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final OAuthTokens? latest = OAuthTokens.tryDecode(
          await _secrets.read(accountId),
        );
        if (latest != null && !latest.isExpired()) return latest.accessToken;
      }
      throw StateError('Timed out waiting for the OAuth token refresh lease.');
    }
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
    } finally {
      await _releaseRefreshLease(accountId);
    }
  }

  Future<bool> _acquireRefreshLease(String accountId) async {
    if (kIsWeb || !crossProcessLeases) return true;
    return rust.acquireOauthRefreshLease(
      accountId: accountId,
      ownerId: _refreshOwnerId,
      nowMs: _ms(DateTime.now().millisecondsSinceEpoch),
      leaseDurationMs: _ms(15000),
    );
  }

  Future<void> _releaseRefreshLease(String accountId) async {
    if (kIsWeb || !crossProcessLeases) return;
    await rust.releaseOauthRefreshLease(
      accountId: accountId,
      ownerId: _refreshOwnerId,
    );
  }

  /// Server-side revoke of the stored tokens, used on sign-out.
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
