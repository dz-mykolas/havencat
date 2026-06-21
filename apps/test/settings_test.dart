import 'package:flutter/material.dart';
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
import 'package:havencat/ui/settings/widgets/account_tile.dart';
import 'package:havencat/ui/settings/widgets/add_account_dialog.dart';

/// Settings screen tests.
///
/// The app seeds a mock account on startup, so the accounts list is never
/// empty in these tests. The mock account has no API key (it doesn't need
/// one), so it serves as the "active by default" account we can deactivate
/// by adding + activating an API-key account.
void main() {
  testWidgets('renders the seeded mock account and an Add button', (
    WidgetTester tester,
  ) async {
    await _pump(tester);

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Accounts'), findsOneWidget);
    expect(find.text('Mock'), findsOneWidget);
    expect(find.byTooltip('Add account'), findsOneWidget);
  });

  testWidgets('opening Add Account and submitting adds a new account', (
    WidgetTester tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.byTooltip('Add account'));
    await tester.pumpAndSettle();

    // The provider picker bottom sheet shows all providers grouped into
    // subscription + API-key sections. Tap the OpenAI-compatible tile to
    // dismiss the sheet and open the AddAccountDialog with that provider
    // pre-selected.
    await tester.tap(find.text('OpenAI-compatible').first);
    await tester.pumpAndSettle();
    expect(find.byType(AddAccountDialog), findsOneWidget);

    // Display name is prefilled from the provider; just enter the API key.
    await tester.enterText(
      find.widgetWithText(TextField, 'API key'),
      'sk-test',
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    // The dialog closed and the new account appears in the list.
    expect(find.text('OpenAI-compatible'), findsWidgets);
    expect(find.byType(AddAccountDialog), findsNothing);
  });

  testWidgets('tapping an inactive account activates it', (
    WidgetTester tester,
  ) async {
    await _pump(tester);

    // Add an account so there are two to switch between.
    await _addOpenAiAccount(tester, name: 'Second');

    // The mock account is active initially (seeded). Tap the new account's
    // row to activate it. The new account's display name is "Second".
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();

    // The active account shows a check_circle icon; the inactive one shows a
    // delete button. Verify the mock account now has a delete button (i.e.
    // it is no longer active).
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Mock'),
          matching: find.byType(AccountTile),
        ),
        matching: find.byTooltip('Remove account'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('removing an account asks for confirmation then deletes', (
    WidgetTester tester,
  ) async {
    await _pump(tester);
    await _addOpenAiAccount(tester, name: 'To Delete');

    // Activate the mock account so the new one shows a delete button.
    await tester.tap(find.text('Mock'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('To Delete'),
          matching: find.byType(AccountTile),
        ),
        matching: find.byTooltip('Remove account'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Remove account?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.text('To Delete'), findsNothing);
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
      expect(
        ProviderAccount.fromJson(account.toJson()).enabledModels,
        <String>['openai/gpt-5.5', 'anthropic/claude-opus-4-5'],
      );
    });

    test('accepts an empty enabledModels list and creates the account', () async {
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
    });

    test('enabledModels null leaves the legacy `model`-only config intact',
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
    });
  });
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(const ProviderScope(child: HavenChatApp()));
  await tester.tap(find.byTooltip('Settings'));
  await tester.pumpAndSettle();
  expect(find.byType(SettingsScreen), findsOneWidget);
}

/// Adds an OpenAI-compatible account via the provider picker + Add Account
/// dialog with the given [name], entering a dummy API key.
Future<void> _addOpenAiAccount(
  WidgetTester tester, {
  required String name,
}) async {
  await tester.tap(find.byTooltip('Add account'));
  await tester.pumpAndSettle();
  // Tap the OpenAI-compatible tile in the picker sheet; this dismisses the
  // sheet and opens AddAccountDialog with the provider pre-selected.
  await tester.tap(find.text('OpenAI-compatible').first);
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextField, 'Display name'), name);
  await tester.enterText(find.widgetWithText(TextField, 'API key'), 'sk-test');
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, 'Add'));
  await tester.pumpAndSettle();
}
