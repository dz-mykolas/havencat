import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

/// The result of a successful device-code login: the tokens + the decoded
/// account info (plan type, account id) extracted from the JWT.
///
/// We don't validate the JWT signature client-side — we only decode its
/// payload to read display metadata (plan type, account id). The token's
/// authenticity is the auth server's responsibility; we just use it.
class ChatGptAuthResult {
  const ChatGptAuthResult({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.accountId,
    required this.planType,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;

  /// `chatgpt_account_id` claim from the JWT, if present.
  final String? accountId;

  /// `chatgpt_plan_type` claim from the JWT (e.g. 'free', 'plus', 'pro').
  final String? planType;
}

/// The intermediate state after requesting a device code: the URL the user
/// visits and the code they enter. The app shows these, then polls
/// [ChatGptOAuthFlow.pollForAuthorizationCode] until the user completes
/// sign-in.
class DeviceCodeResponse {
  const DeviceCodeResponse({
    required this.deviceAuthId,
    required this.userCode,
    required this.verificationUrl,
    required this.interval,
  });

  /// Server-internal id (sent back when polling). NOT the user code.
  final String deviceAuthId;
  final String userCode;
  final String verificationUrl;

  /// Polling interval in seconds.
  final int interval;

  /// Client-side device-code lifetime. OpenAI's usercode endpoint does not
  /// return `expires_in`; Codex hardcodes 15 minutes and so do we.
  static const int lifetimeSeconds = 15 * 60;
}

/// The result of step 2: the authorization code + the PKCE codes the server
/// generated for this device-code login. Passed to
/// [ChatGptOAuthFlow.exchangeCodeForTokens].
class DeviceAuthCode {
  const DeviceAuthCode({
    required this.authorizationCode,
    required this.codeVerifier,
    required this.codeChallenge,
  });

  final String authorizationCode;
  final String codeVerifier;
  final String codeChallenge;
}

/// ChatGPT device-code OAuth flow.
///
/// This is NOT standard RFC 8628. ChatGPT's auth server exposes a custom
/// two-phase device flow on top of a standard authorization-code + PKCE
/// exchange:
///
///   1. Request a user code: `POST {issuer}/api/accounts/deviceauth/usercode`
///      with `{"client_id": ...}`. Returns `device_auth_id`, `user_code`,
///      and an `interval` (encoded as a string).
///   2. Poll for an authorization code:
///      `POST {issuer}/api/accounts/deviceauth/token` with
///      `{"device_auth_id", "user_code"}`. While the user hasn't completed
///      sign-in the server returns 403/404; on success it returns an
///      `authorization_code` plus the PKCE `code_verifier` / `code_challenge`
///      the server generated for this login.
///   3. Exchange the authorization code for tokens:
///      `POST {issuer}/oauth/token` (form-urlencoded) with the standard
///      `authorization_code` grant, the server-provided `code_verifier`,
///      and a fixed `redirect_uri` of `{issuer}/deviceauth/callback`.
///
/// The user visits `{issuer}/codex/device` in their browser and enters the
/// `user_code` manually — there is no pre-filled `verification_uri_complete`
/// in this flow.
///
/// This mirrors what Codex CLI does in `codex-rs/login/src/device_code_auth.rs`.
class ChatGptOAuthFlow {
  ChatGptOAuthFlow({Dio? dio, String? clientId, String? issuer})
    : _dio = dio ?? Dio(),
      _clientId = clientId ?? ChatGptOAuthConfig.clientId,
      _issuer = issuer ?? ChatGptOAuthConfig.issuer;

  final Dio _dio;
  final String _clientId;
  final String _issuer;

  /// Step 1: request a device code. Show the returned [verificationUrl] +
  /// [userCode] to the user.
  Future<DeviceCodeResponse> requestDeviceCode() async {
    final Response<Map<String, dynamic>> response = await _dio.post(
      '${_trimEndSlash(_issuer)}/api/accounts/deviceauth/usercode',
      data: <String, String>{'client_id': _clientId},
      options: Options(
        headers: <String, String>{'Content-Type': 'application/json'},
      ),
    );

    final Map<String, dynamic> body = response.data!;
    return DeviceCodeResponse(
      deviceAuthId: body['device_auth_id'] as String,
      userCode: body['user_code'] as String,
      verificationUrl: '${_trimEndSlash(_issuer)}/codex/device',
      // The server returns `interval` as a string; tolerate either form.
      interval: _parseInt(body['interval']) ?? 5,
    );
  }

  /// Step 2: poll the deviceauth/token endpoint until the user completes
  /// sign-in or the device code expires. Returns the authorization code +
  /// PKCE codes needed for the final token exchange.
  ///
  /// While the user hasn't signed in yet, the server returns 403 or 404 —
  /// these are treated as "keep polling". [onPolling] is called on each
  /// pending attempt so the UI can show progress.
  ///
  /// [shouldCancel] — if it ever returns true, polling stops and a
  /// [ChatGptAuthCancelled] error is thrown.
  Future<DeviceAuthCode> pollForAuthorizationCode({
    required DeviceCodeResponse deviceCode,
    void Function()? onPolling,
    Future<bool> Function()? shouldCancel,
  }) async {
    final String url =
        '${_trimEndSlash(_issuer)}/api/accounts/deviceauth/token';
    final DateTime expiresAt = DateTime.now().add(
      const Duration(seconds: DeviceCodeResponse.lifetimeSeconds),
    );

    while (true) {
      if (shouldCancel != null && await shouldCancel()) {
        throw const ChatGptAuthCancelled();
      }
      if (DateTime.now().isAfter(expiresAt)) {
        throw const ChatGptAuthError('Device code expired. Please try again.');
      }

      try {
        final Response<Map<String, dynamic>> response = await _dio.post(
          url,
          data: <String, String>{
            'device_auth_id': deviceCode.deviceAuthId,
            'user_code': deviceCode.userCode,
          },
          options: Options(
            headers: <String, String>{'Content-Type': 'application/json'},
          ),
        );
        final Map<String, dynamic> body = response.data!;
        return DeviceAuthCode(
          authorizationCode: body['authorization_code'] as String,
          codeVerifier: body['code_verifier'] as String,
          codeChallenge: body['code_challenge'] as String,
        );
      } on DioException catch (e) {
        final int? status = e.response?.statusCode;
        // 403/404 = the user hasn't completed sign-in yet. Keep polling.
        if (status == 403 || status == 404) {
          onPolling?.call();
          await Future<void>.delayed(Duration(seconds: deviceCode.interval));
          continue;
        }
        // Transient network errors (host lookup, connection reset, timeout)
        // are expected here: on mobile, opening the browser to complete
        // sign-in backgrounds the app, and the OS suspends its sockets. The
        // in-flight poll then fails with a SocketException-shaped
        // DioException. Treat these as "keep polling" rather than aborting
        // the whole login — the user is mid-flow in another app.
        if (status == null && _isTransientNetworkError(e)) {
          onPolling?.call();
          await Future<void>.delayed(Duration(seconds: deviceCode.interval));
          continue;
        }
        throw ChatGptAuthError(
          'Device auth failed: ${e.message ?? e.type.name}',
        );
      }
    }
  }

  /// Step 3: exchange the authorization code for tokens. Uses the standard
  /// OAuth `authorization_code` grant with PKCE, form-urlencoded body, and
  /// the fixed `deviceauth/callback` redirect URI.
  Future<ChatGptAuthResult> exchangeCodeForTokens(
    DeviceAuthCode authCode,
  ) async {
    final String redirectUri = '${_trimEndSlash(_issuer)}/deviceauth/callback';
    final Response<Map<String, dynamic>> response = await _dio.post(
      '${_trimEndSlash(_issuer)}/oauth/token',
      data: <String, String>{
        'grant_type': 'authorization_code',
        'code': authCode.authorizationCode,
        'redirect_uri': redirectUri,
        'client_id': _clientId,
        'code_verifier': authCode.codeVerifier,
      },
      options: Options(
        headers: <String, String>{
          'Content-Type': 'application/x-www-form-urlencoded',
        },
      ),
    );
    return _parseTokenResponse(response.data!);
  }

  /// Convenience: run steps 2 + 3 (poll + exchange) end-to-end. This is what
  /// the UI calls after [requestDeviceCode].
  Future<ChatGptAuthResult> completeLogin({
    required DeviceCodeResponse deviceCode,
    void Function()? onPolling,
    Future<bool> Function()? shouldCancel,
  }) async {
    final DeviceAuthCode authCode = await pollForAuthorizationCode(
      deviceCode: deviceCode,
      onPolling: onPolling,
      shouldCancel: shouldCancel,
    );
    return exchangeCodeForTokens(authCode);
  }

  /// Refresh an expired access token using a stored refresh token.
  Future<ChatGptAuthResult> refreshToken(String refreshToken) async {
    final Response<Map<String, dynamic>> response = await _dio.post(
      '${_trimEndSlash(_issuer)}/oauth/token',
      data: <String, String>{
        'grant_type': 'refresh_token',
        'client_id': _clientId,
        'refresh_token': refreshToken,
      },
      options: Options(
        headers: <String, String>{
          'Content-Type': 'application/x-www-form-urlencoded',
        },
      ),
    );
    return _parseTokenResponse(response.data!, refreshToken: refreshToken);
  }

  /// Revoke a token (best-effort, called on sign-out).
  Future<void> revoke(String token) async {
    try {
      await _dio.post(
        '${_trimEndSlash(_issuer)}/oauth/revoke',
        data: <String, String>{'client_id': _clientId, 'token': token},
        options: Options(
          headers: <String, String>{
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        ),
      );
    } on DioException {
      // Best-effort: ignore failures on sign-out.
    }
  }

  ChatGptAuthResult _parseTokenResponse(
    Map<String, dynamic> body, {
    String? refreshToken,
  }) {
    final String accessToken = body['access_token'] as String;
    final String? refresh = (body['refresh_token'] as String?) ?? refreshToken;
    final int? expiresIn = _parseInt(body['expires_in']);
    final DateTime? expiresAt = expiresIn == null
        ? null
        : DateTime.now().add(Duration(seconds: expiresIn));

    final Map<String, dynamic>? claims = _decodeJwtPayload(accessToken);
    final Map<String, dynamic>? authClaim =
        claims?['https://api.openai.com/auth'] as Map<String, dynamic>?;

    return ChatGptAuthResult(
      accessToken: accessToken,
      refreshToken: refresh,
      expiresAt: expiresAt,
      accountId: authClaim?['chatgpt_account_id'] as String?,
      planType: authClaim?['chatgpt_plan_type'] as String?,
    );
  }

  /// Decode a JWT's payload without verifying the signature. We only read
  /// display metadata (plan type, account id) — the token's authenticity is
  /// the auth server's responsibility when we use it.
  Map<String, dynamic>? _decodeJwtPayload(String jwt) {
    try {
      final List<String> parts = jwt.split('.');
      if (parts.length != 3) return null;
      // JWT uses base64url without padding.
      String payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      switch (payload.length % 4) {
        case 2:
          payload += '==';
        case 3:
          payload += '=';
      }
      final String decoded = utf8.decode(base64Url.decode(payload));
      final Object? parsed = jsonDecode(decoded);
      if (parsed is Map<String, dynamic>) return parsed;
      return null;
    } on Object {
      return null;
    }
  }

  /// Parse a value that may be a num or a string-encoded integer.
  static int? _parseInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}

/// Configurable constants for the ChatGPT OAuth flow. The client_id matches
/// the Codex CLI's public client (`CLIENT_ID` in
/// `codex-rs/login/src/auth/manager.rs`). Override via constructor for
/// testing or staging.
class ChatGptOAuthConfig {
  const ChatGptOAuthConfig._();

  static const String issuer = 'https://auth.openai.com';

  /// Codex CLI's public OAuth client id. This is a public client (no client
  /// secret) — device code flow is designed for such clients.
  static const String clientId = 'app_EMoamEEZ73f0CkXaXp7hrann';

  /// The ChatGPT backend API base URL (NOT api.openai.com). Subscription
  /// quota is consumed against this endpoint using the OAuth access token.
  static const String chatgptApiBaseUrl = 'https://chatgpt.com/backend-api';
}

/// Typed errors for the OAuth flow.
sealed class ChatGptAuthException implements Exception {
  const ChatGptAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class ChatGptAuthError extends ChatGptAuthException {
  const ChatGptAuthError(super.message);
}

/// User cancelled the in-progress device code login.
final class ChatGptAuthCancelled extends ChatGptAuthException {
  const ChatGptAuthCancelled() : super('Sign-in cancelled.');
}

/// Strips a single trailing slash from [url], if present.
String _trimEndSlash(String url) =>
    url.endsWith('/') ? url.substring(0, url.length - 1) : url;

/// Whether [e] represents a transient network failure that should be retried
/// rather than surfaced to the user.
///
/// On mobile (notably Android), when the app is backgrounded — e.g. because
/// `launchUrl` opened the browser so the user can complete device-code
/// sign-in — the OS suspends the app's network sockets. Any in-flight Dio
/// request then fails with a `SocketException` ("Failed host lookup",
/// "Connection refused", "Connection reset"). These are not real auth
/// failures; the device code is still valid and polling should resume once
/// the app is foregrounded again. See flutter/flutter#121143 and
/// cfug/dio#2179.
bool _isTransientNetworkError(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.connectionError:
    case DioExceptionType.unknown:
      return true;
    case DioExceptionType.badCertificate:
    case DioExceptionType.badResponse:
    case DioExceptionType.cancel:
      return false;
  }
}
