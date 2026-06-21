import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:http_mock_adapter/src/handlers/request_handler.dart';

import 'package:havencat/data/repositories/provider_account_repository.dart';
import 'package:havencat/data/services/auth/chatgpt_oauth_flow.dart';
import 'package:havencat/data/services/auth/chatgpt_token_service.dart';
import 'package:havencat/data/services/auth/credential_resolver.dart';
import 'package:havencat/data/services/auth/secret_store.dart';
import 'package:havencat/data/services/llm/adapter_registry.dart';
import 'package:havencat/data/services/llm/model_service.dart';
import 'package:havencat/data/services/llm/openai_compatible/openai_compatible_adapter.dart';
import 'package:havencat/data/services/storage/account_store.dart';
import 'package:havencat/data/services/storage/app_settings.dart';
import 'package:havencat/domain/models/adapter_kind.dart';
import 'package:havencat/domain/models/llm_model.dart';
import 'package:havencat/domain/models/provider_account.dart';
import 'package:havencat/providers.dart';
import 'package:havencat/ui/chat/model_selector_viewmodel.dart';
import 'package:havencat/ui/chat/widgets/model_selector_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OpenAiCompatibleAdapter.listModels', () {
    test('parses the OpenAI /models list shape', () async {
      final Dio dio = Dio();
      final DioAdapter mock = DioAdapter(dio: dio);
      mock.onGet('https://api.openai.com/v1/models', (MockServer server) {
        server.reply(200, <String, dynamic>{
          'object': 'list',
          'data': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'gpt-4o', 'object': 'model'},
            <String, dynamic>{'id': 'gpt-4o-mini', 'object': 'model'},
            <String, dynamic>{'id': 'o3', 'object': 'model'},
          ],
        });
      });

      final OpenAiCompatibleAdapter adapter = OpenAiCompatibleAdapter(dio: dio);
      final List<LlmModel> models = await adapter.listModels(
        account: ProviderAccount(
          id: 'a',
          kind: AdapterKind.openaiCompatible,
          displayName: 'OpenAI',
          config: const <String, Object?>{},
        ),
        secret: 'sk-test',
      );

      expect(models.map((LlmModel m) => m.id), <String>[
        'gpt-4o',
        'gpt-4o-mini',
        'o3',
      ]);
    });
  });

  group('ModelSelectorViewModel', () {
    ModelSelectorViewModel buildVm({AppSettings? settings}) {
      final SecretStore secrets = SecretStore();
      final ProviderAccountRepository providers = ProviderAccountRepository(
        accountStore: AccountStore(),
        secretStore: secrets,
      );
      final ModelService service = ModelService(
        adapters: AdapterRegistry(),
        credentials: CredentialResolver(
          secretStore: secrets,
          chatGptTokens: ChatGptTokenService(
            secretStore: secrets,
            oauthFlow: ChatGptOAuthFlow(
              clientId: 'c',
              issuer: 'https://auth.test',
            ),
          ),
        ),
      );
      return ModelSelectorViewModel(providers, service, settings ?? AppSettings());
    }

    test('fetches models for the active (mock) provider', () async {
      final ModelSelectorViewModel vm = buildVm();
      await vm.refresh();
      expect(vm.isLoading, isFalse);
      expect(vm.error, isNull);
      expect(vm.models, isNotEmpty);
    });

    test('selects a default from the visible models, not a hidden one',
        () async {
      final SecretStore secrets = SecretStore();
      final ProviderAccountRepository providers = ProviderAccountRepository(
        accountStore: AccountStore(),
        secretStore: secrets,
      );
      final ModelSelectorViewModel vm = ModelSelectorViewModel(
        providers,
        _FixedModelService(const <LlmModel>[
          LlmModel(id: 'hidden-1', hidden: true),
          LlmModel(id: 'visible-1'),
        ]),
        AppSettings(),
      );
      await vm.refresh();
      // Default skips the hidden model and lands on the first visible one.
      expect(vm.selectedModelId, 'visible-1');
    });

    test('hides models flagged hidden until the global setting is enabled',
        () async {
      final SecretStore secrets = SecretStore();
      final ProviderAccountRepository providers = ProviderAccountRepository(
        accountStore: AccountStore(),
        secretStore: secrets,
      );
      final AppSettings settings = AppSettings();
      final ModelSelectorViewModel vm = ModelSelectorViewModel(
        providers,
        _FixedModelService(const <LlmModel>[
          LlmModel(id: 'visible-1'),
          LlmModel(id: 'hidden-1', hidden: true),
        ]),
        settings,
      );
      await vm.refresh();

      expect(vm.models.map((LlmModel m) => m.id), <String>['visible-1']);

      await settings.setShowHiddenModels(true);
      expect(vm.models.map((LlmModel m) => m.id), <String>[
        'visible-1',
        'hidden-1',
      ]);
    });
  });

  group('ModelSelectorBar provider picker grey-out', () {
    testWidgets(
        'an account with no enabledModels is greyed out and non-selectable',
        (WidgetTester tester) async {
      final SecretStore secrets = SecretStore();
      // Seed two accounts directly: one with an enabled model, one without.
      // We bypass the repository's addApiKeyAccount to set exact config shapes.
      final ProviderAccountRepository providers = ProviderAccountRepository(
        accountStore: AccountStore(),
        secretStore: secrets,
      );
      // Account A: enabledModels present and non-empty -> selectable.
      await providers.addApiKeyAccount(
        definitionId: 'openai_compatible',
        displayName: 'With Models',
        apiKey: 'sk-a',
        config: const <String, Object?>{
          'enabledModels': <String>['gpt-5.5'],
        },
      );
      // Account B: explicitly empty enabledModels -> greyed out.
      await providers.addApiKeyAccount(
        definitionId: 'openai_compatible',
        displayName: 'No Models',
        apiKey: 'sk-b',
        config: const <String, Object?>{
          'enabledModels': <String>[],
        },
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            providerAccountRepositoryProvider
                .overrideWith((ref) => providers),
            modelServiceProvider.overrideWithValue(
              _FixedModelService(const <LlmModel>[LlmModel(id: 'gpt-5.5')]),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: ModelSelectorBar())),
        ),
      );
      await tester.pumpAndSettle();

      // Open the provider picker popup by tapping the provider chip (the
      // account-tree icon button in the selector bar).
      await tester.tap(find.byIcon(Icons.account_tree_outlined).first);
      await tester.pumpAndSettle();

      // "With Models" entry is enabled (selectable, has no lock icon).
      final Finder withRow = find.ancestor(
        of: find.text('With Models'),
        matching: find.byType(PopupMenuItem<String>),
      );
      expect(withRow, findsOneWidget);
      expect(
        tester.widget<PopupMenuItem<String>>(withRow).enabled,
        isTrue,
      );

      // "No Models" entry is disabled (no trailing check + lock icon visible).
      final Finder withoutRow = find.ancestor(
        of: find.text('No Models'),
        matching: find.byType(PopupMenuItem<String>),
      );
      expect(withoutRow, findsOneWidget);
      expect(
        tester.widget<PopupMenuItem<String>>(withoutRow).enabled,
        isFalse,
      );
      expect(
        find.descendant(of: withoutRow, matching: find.byIcon(Icons.lock_outline)),
        findsOneWidget,
      );
    });

    testWidgets('an account with at least one enabled model is selectable',
        (WidgetTester tester) async {
      final SecretStore secrets = SecretStore();
      final ProviderAccountRepository providers = ProviderAccountRepository(
        accountStore: AccountStore(),
        secretStore: secrets,
      );
      // Legacy single-`model` config (no `enabledModels` key) — the accessor
      // falls back to `[model]`, so this account should be selectable too.
      await providers.addApiKeyAccount(
        definitionId: 'openai_compatible',
        displayName: 'Legacy Single',
        apiKey: 'sk-legacy',
        config: const <String, Object?>{'model': 'gpt-5.5'},
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            providerAccountRepositoryProvider
                .overrideWith((ref) => providers),
            modelServiceProvider.overrideWithValue(
              _FixedModelService(const <LlmModel>[LlmModel(id: 'gpt-5.5')]),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: ModelSelectorBar())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.account_tree_outlined).first);
      await tester.pumpAndSettle();

      final Finder row = find.ancestor(
        of: find.text('Legacy Single'),
        matching: find.byType(PopupMenuItem<String>),
      );
      expect(row, findsOneWidget);
      expect(tester.widget<PopupMenuItem<String>>(row).enabled, isTrue);
      expect(
        find.descendant(of: row, matching: find.byIcon(Icons.lock_outline)),
        findsNothing,
      );
    });
  });
}

/// A [ModelService] that returns a fixed list, for testing the view model's
/// hidden-model filtering independent of any adapter.
class _FixedModelService extends ModelService {
  _FixedModelService(this._models)
    : super(
        adapters: AdapterRegistry(),
        credentials: CredentialResolver(
          secretStore: SecretStore(),
          chatGptTokens: ChatGptTokenService(
            secretStore: SecretStore(),
            oauthFlow: ChatGptOAuthFlow(
              clientId: 'c',
              issuer: 'https://auth.test',
            ),
          ),
        ),
      );

  final List<LlmModel> _models;

  @override
  Future<List<LlmModel>> list(ProviderAccount account) async => _models;
}
