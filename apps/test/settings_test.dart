import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/app.dart';
import 'package:app/data/repositories/provider_account_repository.dart';
import 'package:app/data/services/auth/chatgpt_oauth_flow.dart';
import 'package:app/data/services/auth/chatgpt_token_service.dart';
import 'package:app/data/services/auth/secret_store.dart';
import 'package:app/data/services/storage/account_store.dart';
import 'package:app/domain/models/provider_account.dart';
import 'package:app/ui/pricing/pricing_viewmodel.dart';
import 'package:app/ui/settings/settings_screen.dart';
import 'package:app/ui/settings/settings_viewmodel.dart';

/// Settings tests.
///
/// One smoke widget test verifies the Discover panel's Accounts tab is
/// reachable and renders the seeded mock account. The activate / remove /
/// add-account flows are thin wiring over `SettingsViewModel`, whose real
/// logic (config shape, enabledModels handling) is covered by the unit
/// tests below — those run fast and don't break on layout tweaks.
void main() {
  testWidgets('mobile settings opens categories as separate detail views', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SettingsScreen())),
    );

    expect(find.text('Models & providers'), findsOneWidget);
    expect(find.text('Web search'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Context'), findsOneWidget);
    expect(find.text('Show hidden models'), findsNothing);

    await tester.tap(find.text('Models & providers'));
    await tester.pump(const Duration(milliseconds: 250));
    final Finder modelsTab = find.ancestor(
      of: find.text('Models'),
      matching: find.byType(InkWell),
    );
    final Finder indicator = find.byKey(
      const ValueKey<String>('compact-tab-indicator'),
    );
    final double indicatorStart = tester.getTopLeft(indicator).dx;
    expect(tester.getSize(modelsTab).height, 56);
    expect(
      tester.widget<InkWell>(modelsTab).overlayColor!.resolve(<WidgetState>{
        WidgetState.pressed,
      }),
      Colors.transparent,
    );
    await tester.tapAt(
      Offset(
        tester.getCenter(modelsTab).dx,
        tester.getBottomLeft(modelsTab).dy - 2,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final double indicatorMid = tester.getTopLeft(indicator).dx;
    await tester.pump(const Duration(milliseconds: 200));
    final double indicatorEnd = tester.getTopLeft(indicator).dx;
    expect(indicatorMid, greaterThan(indicatorStart));
    expect(indicatorMid, lessThan(indicatorEnd));
    expect(
      ProviderScope.containerOf(
        tester.element(find.text('Models')),
      ).read(pricingViewModelProvider).scope,
      PricingScope.models,
    );
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('General'));
    await tester.pumpAndSettle();
    expect(find.text('Show hidden models'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Show hidden models'), findsNothing);
    expect(find.text('Models & providers'), findsOneWidget);

    await tester.tap(find.text('Web search'));
    await tester.pumpAndSettle();
    expect(find.text('Search providers'), findsOneWidget);
    expect(find.text('Exa'), findsOneWidget);
    expect(find.text('Brave Search'), findsOneWidget);
    expect(find.text('SearXNG'), findsOneWidget);
  });

  testWidgets('settings can open directly to web search', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: SettingsScreen(initialSection: SettingsSection.webSearch),
        ),
      ),
    );

    expect(find.text('Search providers'), findsOneWidget);
    expect(find.text('SearXNG'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);

    await tester.tap(find.text('SearXNG'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Instance address'),
      'search.dzmykolas.place',
    );
    await tester.pump();

    DropdownButton<String> scheme = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(scheme.value, 'https');

    await tester.enterText(
      find.widgetWithText(TextField, 'Instance address'),
      'localhost:8080',
    );
    await tester.pump();
    scheme = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(scheme.value, 'http');

    await tester.enterText(
      find.widgetWithText(TextField, 'Instance address'),
      'https://search.dzmykolas.place',
    );
    await tester.pump();
    expect(find.text('search.dzmykolas.place'), findsOneWidget);
    scheme = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(scheme.value, 'https');

    await tester.enterText(
      find.widgetWithText(TextField, 'Instance address'),
      'localhost:8080',
    );
    await tester.pump();
    scheme = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(scheme.value, 'https');

    await tester.tap(find.byKey(const ValueKey<String>('instance-url-scheme')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HTTP').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Instance address'),
      'search.dzmykolas.place',
    );
    await tester.pump();
    scheme = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(scheme.value, 'http');
    expect(
      find.text('Public SearXNG instances require HTTPS.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Instance address'),
      '192.168.1.20:8080',
    );
    await tester.pump();
    expect(
      find.textContaining('Local HTTP traffic is unencrypted'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNotNull,
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Access token (optional)'),
      'access-token',
    );
    await tester.pump();
    expect(
      find.text('Access tokens require HTTPS outside this device.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('Accounts tab renders the seeded mock account', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: App()));
    await tester.dragFrom(const Offset(400, 300), const Offset(260, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    await tester.tap(find.text('Accounts'));
    await tester.pumpAndSettle();
    expect(find.text('Mock'), findsOneWidget);
  });

  test('credential cleanup failure aborts account removal', () async {
    final AccountStore store = AccountStore();
    final SecretStore secrets = _FailingDeleteSecretStore();
    final ProviderAccountRepository initial = ProviderAccountRepository(
      accountStore: store,
      secretStore: secrets,
    );
    await initial.load();
    await expectLater(
      initial.remove(initial.accounts.single.id),
      throwsStateError,
    );

    final ProviderAccountRepository reloaded = ProviderAccountRepository(
      accountStore: store,
      secretStore: secrets,
    );
    await reloaded.load();

    expect(reloaded.accounts, hasLength(1));
    expect(reloaded.activeAccountId, reloaded.accounts.single.id);
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

class _FailingDeleteSecretStore extends SecretStore {
  @override
  Future<void> delete(String id) async {
    throw StateError('Secure storage is unavailable');
  }
}
