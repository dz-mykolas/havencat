import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/repositories/provider_account_repository.dart';
import 'package:app/data/services/auth/chatgpt_oauth_flow.dart';
import 'package:app/data/services/auth/chatgpt_token_service.dart';
import 'package:app/data/services/auth/poe_oauth_flow.dart';
import 'package:app/data/services/auth/secret_store.dart';
import 'package:app/data/services/storage/account_store.dart';
import 'package:app/domain/models/app_theme_preferences.dart';
import 'package:app/domain/models/model_pricing.dart';
import 'package:app/domain/models/provider_definition.dart';
import 'package:app/ui/core/theme/app_theme.dart';
import 'package:app/ui/core/widgets/card_visual.dart';
import 'package:app/ui/pricing/widgets/model_card.dart';
import 'package:app/ui/pricing/widgets/model_detail_sheet.dart';
import 'package:app/ui/pricing/widgets/quick_add_sheet.dart';
import 'package:app/ui/settings/settings_viewmodel.dart';

void main() {
  const PricedModel model = PricedModel(
    id: 'provider/model-one',
    name: 'Model One',
    providerId: 'provider',
    providerName: 'Provider',
    labId: 'lab',
    cost: ModelCost(input: 2, output: 8, cacheRead: 0.5),
    contextLimit: 1000000,
    outputLimit: 128000,
    inputModalities: <String>['text', 'image'],
    outputModalities: <String>['text'],
    reasoning: true,
    toolCall: true,
    attachment: true,
    pricingProviderName: 'Provider',
    pricingOfficial: true,
  );

  testWidgets('model details remain readable on a narrow themed surface', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppThemePreset.gradientDark),
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showModelDetailSheet(context, model),
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Model One'), findsOneWidget);
    expect(find.text('Pricing'), findsOneWidget);
    expect(find.text('Capabilities'), findsOneWidget);
    expect(find.text('Reasoning'), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    expect(
      tester.widget<CardVisual>(find.byType(CardVisual)).accentColors,
      hasLength(4),
    );

    final Finder scrollView = find.byType(SingleChildScrollView).first;
    final double topBeforeDrag = tester.getTopLeft(scrollView).dy;
    final TestGesture drag = await tester.startGesture(
      tester.getCenter(find.text('Model One')),
    );
    await drag.moveBy(const Offset(0, 70));
    await tester.pump();
    expect(tester.getTopLeft(scrollView).dy, greaterThan(topBeforeDrag));
    await tester.pump(const Duration(milliseconds: 120));
    await drag.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getTopLeft(scrollView).dy, closeTo(topBeforeDrag, 1));

    final DraggableScrollableSheet sheet = tester
        .widget<DraggableScrollableSheet>(
          find.byType(DraggableScrollableSheet),
        );
    expect(sheet.snap, isFalse);
    expect(sheet.minChildSize, 0.001);
    expect(sheet.maxChildSize, 0.88);

    await tester.fling(find.text('Model One'), const Offset(0, 70), 1800);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getTopLeft(scrollView).dy, greaterThan(700));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Model One'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('model card keeps its hierarchy in compact grids', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppThemePreset.haven),
        home: Center(
          child: SizedBox(
            width: 300,
            height: 96,
            child: ModelCard(model: model, onTap: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Model One'), findsOneWidget);
    expect(find.text('Provider'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Quick Add reacts to fields and protects API credentials', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final SecretStore secrets = SecretStore();
    final ProviderAccountRepository accounts = ProviderAccountRepository(
      accountStore: AccountStore(),
      secretStore: secrets,
    );
    final ChatGptOAuthFlow chatGpt = ChatGptOAuthFlow(
      clientId: 'client',
      issuer: 'https://auth.test',
    );
    final SettingsViewModel settings = SettingsViewModel(
      accounts,
      chatGpt,
      ChatGptTokenService(secretStore: secrets, oauthFlow: chatGpt),
      PoeOAuthFlow(credentialStore: secrets, clientId: 'poe-client'),
    );
    addTearDown(settings.dispose);

    const ProviderModels group = ProviderModels(
      id: 'provider',
      name: 'Provider',
      apiUrl: 'https://api.example.com/v1',
      models: <PricedModel>[model],
    );
    final ProviderDefinition definition = ProviderDefinition(
      id: 'openai_compatible',
      kind: ProviderCatalog.byId('openai_compatible')!.kind,
      displayName: 'Provider',
      description: 'Provider API',
      configTemplate: const <String, Object?>{
        'baseUrl': 'https://api.example.com/v1',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppThemePreset.parchment),
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showQuickAdd(context, settings, group, definition),
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'API key'), 'secret');
    await tester.tap(find.text('Model One'));
    await tester.pump();

    FilledButton addButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Add'),
    );
    expect(addButton.onPressed, isNotNull);

    await tester.tap(find.text('Edit endpoint'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Base URL'),
      'http://api.example.com/v1',
    );
    await tester.pump();
    expect(find.text('Public endpoints require HTTPS.'), findsOneWidget);
    addButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Add'),
    );
    expect(addButton.onPressed, isNull);

    await tester.enterText(
      find.widgetWithText(TextField, 'Base URL'),
      'https://api.example.com/v1',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(
      accounts.accounts
          .where((account) => account.config['catalogProviderId'] == group.id)
          .length,
      1,
    );
  });
}
