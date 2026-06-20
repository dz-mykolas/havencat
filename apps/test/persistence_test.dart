import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:http_mock_adapter/src/handlers/request_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:havencat/data/repositories/provider_account_repository.dart';
import 'package:havencat/data/services/auth/chatgpt_oauth_flow.dart';
import 'package:havencat/data/services/auth/chatgpt_token_service.dart';
import 'package:havencat/data/services/auth/secret_store.dart';
import 'package:havencat/data/services/storage/account_store.dart';
import 'package:havencat/domain/models/adapter_kind.dart';
import 'package:havencat/domain/models/oauth_tokens.dart';
import 'package:havencat/domain/models/provider_account.dart';

/// Tests for the persistence + token-lifecycle layer added so a login survives
/// an app restart / browser refresh in this fully-local (no backend) app.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OAuthTokens', () {
    test('encode/decode round-trips', () {
      final OAuthTokens tokens = OAuthTokens(
        accessToken: 'at',
        refreshToken: 'rt',
        expiresAt: DateTime.utc(2030, 1, 2, 3, 4, 5),
      );
      final OAuthTokens? decoded = OAuthTokens.tryDecode(tokens.encode());
      expect(decoded, isNotNull);
      expect(decoded!.accessToken, 'at');
      expect(decoded.refreshToken, 'rt');
      expect(decoded.expiresAt, DateTime.utc(2030, 1, 2, 3, 4, 5));
    });

    test('tryDecode treats a bare token string as a legacy access token', () {
      final OAuthTokens? decoded = OAuthTokens.tryDecode('legacy-access-token');
      expect(decoded!.accessToken, 'legacy-access-token');
      expect(decoded.canRefresh, isFalse);
    });

    test('isExpired honors the leeway window', () {
      final OAuthTokens almostExpired = OAuthTokens(
        accessToken: 'at',
        expiresAt: DateTime.now().add(const Duration(seconds: 30)),
      );
      expect(almostExpired.isExpired(), isTrue); // within 60s leeway
      final OAuthTokens fresh = OAuthTokens(
        accessToken: 'at',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );
      expect(fresh.isExpired(), isFalse);
    });
  });

  group('ProviderAccountRepository persistence', () {
    test('restores accounts + active id across a simulated restart', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final SecretStore secrets = SecretStore();

      // First "launch": add an API-key account.
      final ProviderAccountRepository repo1 = ProviderAccountRepository(
        accountStore: AccountStore(prefs: prefs),
        secretStore: secrets,
      );
      await repo1.load();
      final ProviderAccount added = await repo1.addApiKeyAccount(
        definitionId: 'openai_compatible',
        displayName: 'OpenAI personal',
        apiKey: 'sk-test',
      );
      await repo1.setActive(added.id);

      // Second "launch": a brand-new repository reading the same storage.
      final ProviderAccountRepository repo2 = ProviderAccountRepository(
        accountStore: AccountStore(prefs: prefs),
        secretStore: secrets,
      );
      await repo2.load();

      expect(repo2.accounts.any((a) => a.id == added.id), isTrue);
      expect(repo2.activeAccountId, added.id);
      expect(
        repo2.accounts.firstWhere((a) => a.id == added.id).displayName,
        'OpenAI personal',
      );
    });

    test('subscription token bundle is recoverable after restart', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final SecretStore secrets = SecretStore();

      final ProviderAccountRepository repo1 = ProviderAccountRepository(
        accountStore: AccountStore(prefs: prefs),
        secretStore: secrets,
      );
      await repo1.load();
      final ProviderAccount account = await repo1.addSubscriptionAccount(
        definitionId: 'chatgpt_subscription',
        displayName: 'ChatGPT (plus)',
        tokens: OAuthTokens(
          accessToken: 'access-1',
          refreshToken: 'refresh-1',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
        config: const <String, Object?>{'planType': 'plus'},
      );

      final ProviderAccountRepository repo2 = ProviderAccountRepository(
        accountStore: AccountStore(prefs: prefs),
        secretStore: secrets,
      );
      await repo2.load();

      final ProviderAccount restored = repo2.accounts.firstWhere(
        (a) => a.id == account.id,
      );
      expect(restored.kind, AdapterKind.subscription);
      expect(restored.config['planType'], 'plus');
      // The secret bundle survives and never leaked into plaintext config.
      expect(restored.config.containsKey('refreshToken'), isFalse);
      final OAuthTokens? bundle = OAuthTokens.tryDecode(
        await secrets.read(account.id),
      );
      expect(bundle!.accessToken, 'access-1');
      expect(bundle.refreshToken, 'refresh-1');
    });
  });

  group('ChatGptTokenService', () {
    test('returns the stored token when it is still valid', () async {
      final SecretStore secrets = SecretStore();
      final ChatGptTokenService svc = ChatGptTokenService(
        secretStore: secrets,
        oauthFlow: ChatGptOAuthFlow(clientId: 'c', issuer: 'https://auth.test'),
      );
      await secrets.write(
        'acct',
        OAuthTokens(
          accessToken: 'still-good',
          refreshToken: 'r',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ).encode(),
      );

      expect(await svc.validAccessToken('acct'), 'still-good');
    });

    test('refreshes an expired token and persists the new bundle', () async {
      final Dio dio = Dio();
      final DioAdapter adapter = DioAdapter(dio: dio);
      adapter.onPost('https://auth.test/oauth/token', (MockServer server) {
        server.reply(200, <String, dynamic>{
          'access_token': 'new-access',
          'refresh_token': 'new-refresh',
          'expires_in': 3600,
        });
      }, data: Matchers.any);

      final SecretStore secrets = SecretStore();
      final ChatGptTokenService svc = ChatGptTokenService(
        secretStore: secrets,
        oauthFlow: ChatGptOAuthFlow(
          dio: dio,
          clientId: 'c',
          issuer: 'https://auth.test',
        ),
      );
      await secrets.write(
        'acct',
        OAuthTokens(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
          expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        ).encode(),
      );

      expect(await svc.validAccessToken('acct'), 'new-access');

      final OAuthTokens? stored = OAuthTokens.tryDecode(
        await secrets.read('acct'),
      );
      expect(stored!.accessToken, 'new-access');
      expect(stored.refreshToken, 'new-refresh');
    });

    test('returns null when signed out (no stored tokens)', () async {
      final SecretStore secrets = SecretStore();
      final ChatGptTokenService svc = ChatGptTokenService(
        secretStore: secrets,
        oauthFlow: ChatGptOAuthFlow(clientId: 'c', issuer: 'https://auth.test'),
      );
      expect(await svc.validAccessToken('missing'), isNull);
    });

    test('concurrent calls share a single refresh (single-flight)', () async {
      final Dio dio = Dio();
      int tokenCalls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest:
              (RequestOptions options, RequestInterceptorHandler handler) {
                tokenCalls++;
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: <String, dynamic>{
                      'access_token': 'refreshed',
                      'refresh_token': 'rotated',
                      'expires_in': 3600,
                    },
                  ),
                );
              },
        ),
      );

      final SecretStore secrets = SecretStore();
      final ChatGptTokenService svc = ChatGptTokenService(
        secretStore: secrets,
        oauthFlow: ChatGptOAuthFlow(
          dio: dio,
          clientId: 'c',
          issuer: 'https://auth.test',
        ),
      );
      await secrets.write(
        'acct',
        OAuthTokens(
          accessToken: 'old',
          refreshToken: 'r',
          expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        ).encode(),
      );

      final List<String?> results = await Future.wait(<Future<String?>>[
        svc.validAccessToken('acct'),
        svc.validAccessToken('acct'),
        svc.validAccessToken('acct'),
      ]);

      expect(results, everyElement('refreshed'));
      expect(tokenCalls, 1); // all three shared one network refresh
    });
  });
}
