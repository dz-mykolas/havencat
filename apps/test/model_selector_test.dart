import 'package:dio/dio.dart';
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
import 'package:havencat/ui/chat/model_selector_viewmodel.dart';

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
