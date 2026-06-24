import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:http_mock_adapter/src/handlers/request_handler.dart';

import 'package:app/data/services/auth/chatgpt_oauth_flow.dart';

/// Tests for the ChatGPT device-code OAuth flow.
///
/// The real ChatGPT flow is NOT standard RFC 8628. It's a custom 3-step flow:
///   1. POST {issuer}/api/accounts/deviceauth/usercode  → device_auth_id + user_code
///   2. POST {issuer}/api/accounts/deviceauth/token     → polls; 403/404 = pending,
///      200 = authorization_code + code_verifier + code_challenge
///   3. POST {issuer}/oauth/token (form-urlencoded)      → access_token + refresh_token
///
/// Uses [DioAdapter] for non-stateful responses and a custom Dio
/// `InterceptorsWrapper` for stateful "first pending, then success" behavior
/// (http_mock_adapter consumes each route after one match).
void main() {
  late Dio dio;
  late DioAdapter adapter;
  late ChatGptOAuthFlow flow;

  /// Build a fake JWT with a given payload. Signature is garbage — we only
  /// decode the payload client-side, never verify it.
  String fakeJwt(Map<String, dynamic> payload) {
    final String header = base64Url.encode(
      utf8.encode('{"alg":"none","typ":"JWT"}'),
    );
    final String body = base64Url
        .encode(utf8.encode(jsonEncode(payload)))
        .replaceAll('=', '');
    return '$header.$body.sig';
  }

  setUp(() {
    dio = Dio();
    adapter = DioAdapter(dio: dio);
    flow = ChatGptOAuthFlow(
      dio: dio,
      clientId: 'test-client-id',
      issuer: 'https://auth.test',
    );
  });

  group('requestDeviceCode', () {
    test('parses the device code response (interval as string)', () async {
      adapter.onPost('https://auth.test/api/accounts/deviceauth/usercode', (
        MockServer server,
      ) {
        server.reply(200, <String, dynamic>{
          'device_auth_id': 'dev-auth-123',
          'user_code': 'ABCD-1234',
          'interval': '5',
          'expires_in': '900',
        });
      }, data: Matchers.any);

      final DeviceCodeResponse response = await flow.requestDeviceCode();

      expect(response.deviceAuthId, 'dev-auth-123');
      expect(response.userCode, 'ABCD-1234');
      expect(response.verificationUrl, 'https://auth.test/codex/device');
      expect(response.interval, 5);
      expect(response.expiresIn, 900);
    });

    test('parses the device code response (interval as number)', () async {
      adapter.onPost('https://auth.test/api/accounts/deviceauth/usercode', (
        MockServer server,
      ) {
        server.reply(200, <String, dynamic>{
          'device_auth_id': 'dev-auth-123',
          'user_code': 'ABCD-1234',
          'interval': 10,
        });
      }, data: Matchers.any);

      final DeviceCodeResponse response = await flow.requestDeviceCode();

      expect(response.interval, 10);
      // expires_in defaults to 900 when absent.
      expect(response.expiresIn, 900);
    });
  });

  group('pollForAuthorizationCode', () {
    test('returns auth code + PKCE codes on first successful poll', () async {
      adapter.onPost('https://auth.test/api/accounts/deviceauth/token', (
        MockServer server,
      ) {
        server.reply(200, <String, dynamic>{
          'authorization_code': 'auth-code-789',
          'code_verifier': 'verifier-abc',
          'code_challenge': 'challenge-xyz',
        });
      }, data: Matchers.any);

      final DeviceAuthCode result = await flow.pollForAuthorizationCode(
        deviceCode: const DeviceCodeResponse(
          deviceAuthId: 'dev-auth-123',
          userCode: 'ABCD-1234',
          verificationUrl: 'https://auth.test/codex/device',
          expiresIn: 900,
          interval: 5,
        ),
      );

      expect(result.authorizationCode, 'auth-code-789');
      expect(result.codeVerifier, 'verifier-abc');
      expect(result.codeChallenge, 'challenge-xyz');
    });

    test('polls while server returns 403 (pending)', () async {
      final String jwt = fakeJwt(<String, dynamic>{
        'https://api.openai.com/auth': <String, dynamic>{
          'chatgpt_plan_type': 'free',
        },
      });

      // Stateful: first poll → 403 pending, second poll → 200 with auth code,
      // then the token exchange → 200 with tokens. http_mock_adapter consumes
      // routes after one match, so use a custom interceptor with a counter.
      int calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest:
              (RequestOptions options, RequestInterceptorHandler handler) {
                calls++;
                if (calls == 1) {
                  // First poll: 403 pending.
                  handler.reject(
                    DioException(
                      requestOptions: options,
                      response: Response<dynamic>(
                        requestOptions: options,
                        statusCode: 403,
                      ),
                      type: DioExceptionType.badResponse,
                    ),
                  );
                  return;
                }
                if (calls == 2) {
                  // Second poll: 200 with auth code.
                  handler.resolve(
                    Response<dynamic>(
                      requestOptions: options,
                      statusCode: 200,
                      data: <String, dynamic>{
                        'authorization_code': 'auth-code-789',
                        'code_verifier': 'verifier-abc',
                        'code_challenge': 'challenge-xyz',
                      },
                    ),
                  );
                  return;
                }
                // Token exchange: 200 with tokens.
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: <String, dynamic>{
                      'access_token': jwt,
                      'refresh_token': 'refresh-999',
                      'expires_in': 3600,
                    },
                  ),
                );
              },
        ),
      );

      final List<void> pollingTicks = <void>[];
      final ChatGptAuthResult result = await flow
          .completeLogin(
            deviceCode: const DeviceCodeResponse(
              deviceAuthId: 'dev-auth-123',
              userCode: 'ABCD-1234',
              verificationUrl: '',
              expiresIn: 900,
              interval: 0, // no delay in tests
            ),
            onPolling: () => pollingTicks.add(null),
          )
          .timeout(const Duration(seconds: 10));

      expect(calls, 3); // 2 polls + 1 token exchange
      expect(pollingTicks.length, 1); // one pending tick
      expect(result.accessToken, jwt);
      expect(result.refreshToken, 'refresh-999');
      expect(result.planType, 'free');
    });

    test('polls while server returns 404 (pending)', () async {
      int calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest:
              (RequestOptions options, RequestInterceptorHandler handler) {
                calls++;
                if (calls == 1) {
                  handler.reject(
                    DioException(
                      requestOptions: options,
                      response: Response<dynamic>(
                        requestOptions: options,
                        statusCode: 404,
                      ),
                      type: DioExceptionType.badResponse,
                    ),
                  );
                  return;
                }
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: <String, dynamic>{
                      'authorization_code': 'auth-code',
                      'code_verifier': 'v',
                      'code_challenge': 'c',
                    },
                  ),
                );
              },
        ),
      );

      final DeviceAuthCode result = await flow
          .pollForAuthorizationCode(
            deviceCode: const DeviceCodeResponse(
              deviceAuthId: 'dev-auth-123',
              userCode: 'ABCD-1234',
              verificationUrl: '',
              expiresIn: 900,
              interval: 0,
            ),
          )
          .timeout(const Duration(seconds: 10));

      expect(calls, 2);
      expect(result.authorizationCode, 'auth-code');
    });

    test('throws on unexpected error status (500)', () async {
      adapter.onPost('https://auth.test/api/accounts/deviceauth/token', (
        MockServer server,
      ) {
        server.reply(500, <String, dynamic>{'error': 'server_error'});
      }, data: Matchers.any);

      await expectLater(
        flow.pollForAuthorizationCode(
          deviceCode: const DeviceCodeResponse(
            deviceAuthId: 'dev-auth-123',
            userCode: 'ABCD-1234',
            verificationUrl: '',
            expiresIn: 900,
            interval: 0,
          ),
        ),
        throwsA(isA<ChatGptAuthError>()),
      );
    });

    test('respects shouldCancel', () async {
      adapter.onPost('https://auth.test/api/accounts/deviceauth/token', (
        MockServer server,
      ) {
        server.reply(403, <String, dynamic>{});
      }, data: Matchers.any);

      await expectLater(
        flow.pollForAuthorizationCode(
          deviceCode: const DeviceCodeResponse(
            deviceAuthId: 'dev-auth-123',
            userCode: 'ABCD-1234',
            verificationUrl: '',
            expiresIn: 900,
            interval: 0,
          ),
          shouldCancel: () async => true,
        ),
        throwsA(isA<ChatGptAuthCancelled>()),
      );
    });
  });

  group('exchangeCodeForTokens', () {
    test(
      'exchanges auth code for tokens with PKCE + form-urlencoded body',
      () async {
        final String jwt = fakeJwt(<String, dynamic>{
          'sub': 'user-123',
          'https://api.openai.com/auth': <String, dynamic>{
            'chatgpt_account_id': 'acct-456',
            'chatgpt_plan_type': 'plus',
          },
        });

        adapter.onPost('https://auth.test/oauth/token', (MockServer server) {
          server.reply(200, <String, dynamic>{
            'access_token': jwt,
            'refresh_token': 'refresh-789',
            'expires_in': 3600,
          });
        }, data: Matchers.any);

        final ChatGptAuthResult result = await flow.exchangeCodeForTokens(
          const DeviceAuthCode(
            authorizationCode: 'auth-code-789',
            codeVerifier: 'verifier-abc',
            codeChallenge: 'challenge-xyz',
          ),
        );

        expect(result.accessToken, jwt);
        expect(result.refreshToken, 'refresh-789');
        expect(result.expiresAt, isNotNull);
        expect(result.accountId, 'acct-456');
        expect(result.planType, 'plus');
      },
    );
  });

  group('refreshToken', () {
    test('exchanges a refresh token for a new access token', () async {
      final String jwt = fakeJwt(<String, dynamic>{
        'https://api.openai.com/auth': <String, dynamic>{
          'chatgpt_plan_type': 'pro',
        },
      });

      adapter.onPost('https://auth.test/oauth/token', (MockServer server) {
        server.reply(200, <String, dynamic>{
          'access_token': jwt,
          'refresh_token': 'new-refresh',
          'expires_in': 3600,
        });
      }, data: Matchers.any);

      final ChatGptAuthResult result = await flow.refreshToken('old-refresh');

      expect(result.accessToken, jwt);
      expect(result.refreshToken, 'new-refresh');
      expect(result.planType, 'pro');
    });
  });
}
