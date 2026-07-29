import 'package:app/data/repositories/provider_account_repository.dart';
import 'package:app/data/services/auth/chatgpt_oauth_flow.dart';
import 'package:app/data/services/auth/chatgpt_token_service.dart';
import 'package:app/data/services/auth/credential_resolver.dart';
import 'package:app/data/services/auth/poe_oauth_flow.dart';
import 'package:app/data/services/auth/secret_store.dart';
import 'package:app/data/services/storage/account_store.dart';
import 'package:app/domain/models/adapter_kind.dart';
import 'package:app/domain/errors/app_failure.dart';
import 'package:app/domain/models/provider_account.dart';
import 'package:app/domain/models/provider_definition.dart';
import 'package:app/ui/settings/settings_viewmodel.dart';
import 'package:app/ui/settings/widgets/provider_picker.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:http_mock_adapter/src/handlers/request_handler.dart';

void main() {
  group('PoeOAuthFlow', () {
    late Dio dio;
    late DioAdapter adapter;
    late SecretStore secrets;
    late PoeOAuthFlow flow;
    late RequestOptions? tokenRequest;

    setUp(() {
      dio = Dio();
      adapter = DioAdapter(dio: dio);
      secrets = SecretStore();
      tokenRequest = null;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest:
              (RequestOptions options, RequestInterceptorHandler handler) {
                tokenRequest = options;
                handler.next(options);
              },
        ),
      );
      int randomCall = 0;
      flow = PoeOAuthFlow(
        credentialStore: secrets,
        clientId: 'poe-client',
        dio: dio,
        authorizationEndpoint: Uri.parse('https://poe.test/oauth/authorize'),
        tokenEndpoint: Uri.parse('https://api.poe.test/token'),
        randomBytes: (int length) => List<int>.filled(length, randomCall++),
      );
    });

    test(
      'builds PKCE authorization and exchanges the callback for a key',
      () async {
        final Uri redirectUri = Uri.parse(
          'http://localhost:43210/oauth/poe/callback',
        );
        final Uri authorization = await flow.begin(redirectUri);

        expect(authorization.host, 'poe.test');
        expect(authorization.queryParameters['client_id'], 'poe-client');
        expect(authorization.queryParameters['redirect_uri'], '$redirectUri');
        expect(authorization.queryParameters['scope'], 'apikey:create');
        expect(authorization.queryParameters['code_challenge_method'], 'S256');
        expect(authorization.queryParameters['code_challenge'], isNotEmpty);
        final String state = authorization.queryParameters['state']!;

        adapter.onPost(
          'https://api.poe.test/token',
          (MockServer server) => server.reply(200, <String, Object?>{
            'api_key': 'pk-poe',
            'api_key_expires_in': 3600,
          }),
          data: Matchers.any,
        );

        final PoeOAuthResult result = await flow.complete(
          Uri.parse(
            'http://localhost:43210/oauth/poe/callback'
            '?code=authorization-code&state=$state',
          ),
        );

        expect(result.apiKey, 'pk-poe');
        expect(result.expiresAt, isNotNull);
        expect(tokenRequest?.data, containsPair('code', 'authorization-code'));
        expect(tokenRequest?.data, containsPair('client_id', 'poe-client'));
        expect(
          tokenRequest?.data,
          containsPair('redirect_uri', '$redirectUri'),
        );
        expect(tokenRequest?.data, contains('code_verifier'));
        await expectLater(
          flow.complete(
            Uri.parse(
              'http://localhost:43210/oauth/poe/callback'
              '?code=again&state=$state',
            ),
          ),
          throwsA(
            isA<PoeOAuthException>().having(
              (PoeOAuthException error) => error.code,
              'code',
              'missing_session',
            ),
          ),
        );
      },
    );

    test('rejects a callback with a mismatched state', () async {
      await flow.begin(Uri.parse('http://localhost:43210/oauth/poe/callback'));

      await expectLater(
        flow.complete(
          Uri.parse(
            'http://localhost:43210/oauth/poe/callback'
            '?code=authorization-code&state=wrong',
          ),
        ),
        throwsA(
          isA<PoeOAuthException>().having(
            (PoeOAuthException error) => error.code,
            'code',
            'state_mismatch',
          ),
        ),
      );
      expect(tokenRequest, isNull);
    });

    test('requires a configured client id', () async {
      final PoeOAuthFlow unconfigured = PoeOAuthFlow(
        credentialStore: secrets,
        clientId: '',
      );
      await expectLater(
        unconfigured.begin(
          Uri.parse('http://localhost:43210/oauth/poe/callback'),
        ),
        throwsA(
          isA<PoeOAuthException>().having(
            (PoeOAuthException error) => error.code,
            'code',
            'client_not_configured',
          ),
        ),
      );
    });
  });

  test('Poe uses OpenAI-compatible transport and provider-specific auth', () {
    final ProviderDefinition poe = ProviderCatalog.byId('poe_subscription')!;
    expect(poe.kind, AdapterKind.openaiCompatible);
    expect(poe.authMethod, ProviderAuthMethod.poeOAuth);
    expect(poe.configTemplate['baseUrl'], 'https://api.poe.com/v1');
  });

  test('an expired Poe key asks the user to reconnect', () async {
    final SecretStore secrets = SecretStore();
    final ChatGptOAuthFlow chatGpt = ChatGptOAuthFlow(
      clientId: 'chatgpt-client',
      issuer: 'https://auth.test',
    );
    final CredentialResolver resolver = CredentialResolver(
      secretStore: secrets,
      chatGptTokens: ChatGptTokenService(
        secretStore: secrets,
        oauthFlow: chatGpt,
      ),
    );
    final ProviderAccount account = ProviderAccount(
      id: 'poe',
      kind: AdapterKind.openaiCompatible,
      displayName: 'Poe',
      config: <String, Object?>{
        'definitionId': 'poe_subscription',
        'credentialExpiresAt': DateTime.now()
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
      },
    );
    await secrets.write(account.id, 'pk-poe');

    await expectLater(
      resolver.resolve(account),
      throwsA(
        isA<AuthError>().having(
          (AuthError error) => error.message,
          'message',
          contains('Reconnect Poe'),
        ),
      ),
    );
  });

  testWidgets('an existing Poe account does not disable another connection', (
    WidgetTester tester,
  ) async {
    final SecretStore secrets = SecretStore();
    final ProviderAccountRepository accounts = ProviderAccountRepository(
      accountStore: AccountStore(),
      secretStore: secrets,
    );
    await accounts.addApiKeyAccount(
      definitionId: 'poe_subscription',
      displayName: 'Poe',
      apiKey: 'existing-key',
    );
    final ChatGptOAuthFlow chatGpt = ChatGptOAuthFlow(
      clientId: 'chatgpt-client',
      issuer: 'https://auth.test',
    );
    final SettingsViewModel viewModel = SettingsViewModel(
      accounts,
      chatGpt,
      ChatGptTokenService(secretStore: secrets, oauthFlow: chatGpt),
      PoeOAuthFlow(credentialStore: secrets, clientId: 'poe-client'),
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showSubscriptionLogin(
              context,
              viewModel,
              ProviderCatalog.byId('poe_subscription')!,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Connect Poe'), findsOneWidget);
    expect(find.text('Sign in to ChatGPT'), findsNothing);
  });
}
