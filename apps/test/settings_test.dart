import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:havencat/app.dart';
import 'package:havencat/data/repositories/provider_account_repository.dart';
import 'package:havencat/data/services/auth/chatgpt_oauth_flow.dart';
import 'package:havencat/data/services/auth/chatgpt_token_service.dart';
import 'package:havencat/data/services/auth/secret_store.dart';
import 'package:havencat/data/services/storage/account_store.dart';
import 'package:havencat/domain/models/provider_account.dart';
import 'package:havencat/ui/settings/settings_screen.dart';
import 'package:havencat/ui/settings/settings_viewmodel.dart';

/// Settings tests.
///
/// One smoke widget test verifies the Discover panel's Accounts tab is
/// reachable and renders the seeded mock account. The activate / remove /
/// add-account flows are thin wiring over `SettingsViewModel`, whose real
/// logic (config shape, enabledModels handling) is covered by the unit
/// tests below — those run fast and don't break on layout tweaks.
void main() {
  testWidgets('Accounts tab renders the seeded mock account', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    expect(find.text('Mock'), findsOneWidget);
  });

  group('addApiKeyAccount enabledModels', () {
    late SettingsViewModel vm;
    late ProviderAccountRepository providers;

    setUp(() {
      final SecretStore secrets = SecretStore();
      providers = ProviderAccountRepository(
        accountStore: AccountStore(),
        secretStore: secrets,
      );
      final ChatGptOAuthFlow oauth = ChatGptOAuthFlow(
        clientId: 'c',
        issuer: 'https://auth.test',
      );
      final ChatGptTokenService tokens = ChatGptTokenService(
        secretStore: secrets,
        oauthFlow: oauth,
      );
      vm = SettingsViewModel(providers, oauth, tokens);
    });

    test('writes the enabledModels list into account config', () async {
      final account = await vm.addApiKeyAccount(
        definitionId: 'openai_compatible',
        displayName: 'OpenRouter',
        apiKey: 'sk-xyz',
        enabledModels: <String>['openai/gpt-5.5', 'anthropic/claude-opus-4-5'],
      );
      expect(account.config['enabledModels'], <String>[
        'openai/gpt-5.5',
        'anthropic/claude-opus-4-5',
      ]);
      // Single-select `model` field kept in sync with the first enabled entry.
      expect(account.config['model'], 'openai/gpt-5.5');
      // Stringify-then-parse round-trips the new config shape.
      expect(ProviderAccount.fromJson(account.toJson()).enabledModels, <String>[
        'openai/gpt-5.5',
        'anthropic/claude-opus-4-5',
      ]);
    });

    test(
      'accepts an empty enabledModels list and creates the account',
      () async {
        // The Quick-Add flow defaults to no checkboxes selected — the dialog
        // should still save. The chat picker greys the account out until the
        // user later enables at least one model.
        final account = await vm.addApiKeyAccount(
          definitionId: 'openai_compatible',
          displayName: 'Empty',
          apiKey: 'sk-empty',
          enabledModels: <String>[],
        );
        expect(account.enabledModels, isEmpty);
        expect(vm.accounts.any((a) => a.id == account.id), isTrue);
      },
    );

    test(
      'enabledModels null leaves the legacy `model`-only config intact',
      () async {
        // Existing callers that don't pass enabledModels must keep working.
        final account = await vm.addApiKeyAccount(
          definitionId: 'anthropic',
          displayName: 'Anthropic',
          apiKey: 'sk-ant',
        );
        expect(account.config['enabledModels'], isNull);
        // Still model-enabled via the legacy single-model field: the accessor
        // falls back to `[model]` when `enabledModels` is absent.
        expect(account.enabledModels, <String>['claude-3-5-sonnet-latest']);
      },
    );
  });
}
