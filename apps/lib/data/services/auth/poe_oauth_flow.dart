import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'secret_store.dart';

class PoeOAuthResult {
  const PoeOAuthResult({required this.apiKey, this.expiresAt});

  final String apiKey;
  final DateTime? expiresAt;
}

class PoeOAuthException implements Exception {
  const PoeOAuthException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

class PoeOAuthFlow {
  PoeOAuthFlow({
    required SecretStore credentialStore,
    required String clientId,
    Dio? dio,
    Uri? authorizationEndpoint,
    Uri? tokenEndpoint,
    List<int> Function(int length)? randomBytes,
  }) : _secretStore = credentialStore,
       _clientId = clientId.trim(),
       _dio = dio ?? Dio(),
       _authorizationEndpoint =
           authorizationEndpoint ??
           Uri.parse('https://poe.com/oauth/authorize'),
       _tokenEndpoint = tokenEndpoint ?? Uri.parse('https://api.poe.com/token'),
       _randomBytes = randomBytes ?? _secureRandomBytes;

  static const String _pendingSecretId = 'oauth_pending_poe';

  final SecretStore _secretStore;
  final String _clientId;
  final Dio _dio;
  final Uri _authorizationEndpoint;
  final Uri _tokenEndpoint;
  final List<int> Function(int length) _randomBytes;

  bool get isConfigured => _clientId.isNotEmpty;

  Future<Uri> begin(Uri redirectUri) async {
    if (!isConfigured) {
      throw const PoeOAuthException(
        'Poe sign-in is not configured in this build.',
        code: 'client_not_configured',
      );
    }
    if (!redirectUri.hasScheme || !redirectUri.hasAuthority) {
      throw const PoeOAuthException(
        'The Poe callback URL is invalid.',
        code: 'invalid_redirect_uri',
      );
    }

    final String verifier = _base64Url(_randomBytes(32));
    final String challenge = _base64Url(
      sha256.convert(ascii.encode(verifier)).bytes,
    );
    final String state = _base64Url(_randomBytes(32));
    await _secretStore.write(
      _pendingSecretId,
      jsonEncode(<String, String>{
        'state': state,
        'verifier': verifier,
        'redirectUri': redirectUri.toString(),
      }),
    );

    return _authorizationEndpoint.replace(
      queryParameters: <String, String>{
        'client_id': _clientId,
        'redirect_uri': redirectUri.toString(),
        'response_type': 'code',
        'scope': 'apikey:create',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
      },
    );
  }

  Future<PoeOAuthResult> complete(Uri callbackUri) async {
    final _PendingPoeOAuth pending = await _readPending();
    final String? returnedState = callbackUri.queryParameters['state'];
    if (returnedState == null ||
        !_constantTimeEquals(returnedState, pending.state)) {
      await cancel();
      throw const PoeOAuthException(
        'Poe returned an invalid sign-in state. Please try again.',
        code: 'state_mismatch',
      );
    }

    final String? oauthError = callbackUri.queryParameters['error'];
    if (oauthError != null) {
      await cancel();
      throw PoeOAuthException(
        callbackUri.queryParameters['error_description'] ??
            (oauthError == 'access_denied'
                ? 'Poe sign-in was cancelled.'
                : 'Poe sign-in failed.'),
        code: oauthError,
      );
    }

    final String? code = callbackUri.queryParameters['code'];
    if (code == null || code.isEmpty) {
      await cancel();
      throw const PoeOAuthException(
        'Poe did not return an authorization code.',
        code: 'missing_code',
      );
    }

    try {
      final Response<dynamic> response = await _dio.post<dynamic>(
        _tokenEndpoint.toString(),
        data: <String, String>{
          'grant_type': 'authorization_code',
          'client_id': _clientId,
          'code': code,
          'redirect_uri': pending.redirectUri.toString(),
          'code_verifier': pending.verifier,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final Object? body = response.data;
      if (body is! Map) {
        throw const PoeOAuthException(
          'Poe returned an invalid token response.',
          code: 'invalid_token_response',
        );
      }
      final String? apiKey = body['api_key'] as String?;
      if (apiKey == null || apiKey.isEmpty) {
        throw const PoeOAuthException(
          'Poe did not return an API key.',
          code: 'missing_api_key',
        );
      }
      final Object? expiresIn = body['api_key_expires_in'];
      final DateTime? expiresAt = expiresIn is num
          ? DateTime.now().add(Duration(seconds: expiresIn.toInt()))
          : null;
      await cancel();
      return PoeOAuthResult(apiKey: apiKey, expiresAt: expiresAt);
    } on DioException catch (error) {
      final Object? body = error.response?.data;
      final String? code = body is Map ? body['error'] as String? : null;
      final String? description = body is Map
          ? body['error_description'] as String?
          : null;
      throw PoeOAuthException(
        description ?? 'Could not complete Poe sign-in.',
        code: code,
      );
    }
  }

  Future<void> cancel() => _secretStore.delete(_pendingSecretId);

  Future<_PendingPoeOAuth> _readPending() async {
    final String? raw = await _secretStore.read(_pendingSecretId);
    if (raw == null) {
      throw const PoeOAuthException(
        'No pending Poe sign-in was found. Please start again.',
        code: 'missing_session',
      );
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException();
      final String? state = decoded['state'] as String?;
      final String? verifier = decoded['verifier'] as String?;
      final String? redirectUri = decoded['redirectUri'] as String?;
      if (state == null || verifier == null || redirectUri == null) {
        throw const FormatException();
      }
      return _PendingPoeOAuth(
        state: state,
        verifier: verifier,
        redirectUri: Uri.parse(redirectUri),
      );
    } on Object {
      await cancel();
      throw const PoeOAuthException(
        'The pending Poe sign-in is invalid. Please start again.',
        code: 'invalid_session',
      );
    }
  }

  static List<int> _secureRandomBytes(int length) {
    final Random random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  static String _base64Url(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');

  static bool _constantTimeEquals(String left, String right) {
    if (left.length != right.length) return false;
    int difference = 0;
    for (int index = 0; index < left.length; index++) {
      difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
    }
    return difference == 0;
  }
}

class _PendingPoeOAuth {
  const _PendingPoeOAuth({
    required this.state,
    required this.verifier,
    required this.redirectUri,
  });

  final String state;
  final String verifier;
  final Uri redirectUri;
}
