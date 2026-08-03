import 'dart:async';

import 'package:app/app.dart';
import 'package:app/app_router.dart';
import 'package:app/data/services/storage/conversation_store.dart';
import 'package:app/data/services/pricing/models_dev_service.dart';
import 'package:app/domain/errors/app_failure.dart';
import 'package:app/domain/models/conversation.dart';
import 'package:app/domain/models/model_pricing.dart';
import 'package:app/providers.dart';
import 'package:app/ui/chat/chat_screen.dart';
import 'package:app/ui/pricing/pricing_viewmodel.dart';
import 'package:app/ui/settings/poe_oauth_callback_screen.dart';
import 'package:app/ui/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  test('settings sections have stable, reversible route segments', () {
    for (final SettingsSection section in SettingsSection.values) {
      expect(settingsSectionFromRoute(section.routeSegment), section);
      expect(
        settingsRouteFor(section),
        section == SettingsSection.models
            ? '/settings/models/providers'
            : '/settings/${section.routeSegment}',
      );
    }
    expect(settingsRouteFor(null), settingsRoute);
    expect(settingsSectionFromRoute('unknown'), isNull);
  });

  test('catalog routes preserve tabs, groups, and namespaced model ids', () {
    for (final PricingScope scope in PricingScope.values) {
      expect(pricingScopeFromRoute(pricingScopeRouteSegment(scope)), scope);
    }
    expect(pricingScopeFromRoute('unknown'), isNull);
    expect(
      modelsCatalogRouteFor(PricingScope.providers),
      '/settings/models/providers',
    );
    expect(
      modelsCatalogRouteFor(PricingScope.providers, groupId: 'open router'),
      '/settings/models/providers/open%20router',
    );
    expect(
      modelsCatalogRouteFor(PricingScope.models, modelId: 'openai/gpt-5.5'),
      '/settings/models/models/model?id=openai%2Fgpt-5.5',
    );
  });

  test(
    'web provider and failure routes are canonical and contain no secrets',
    () {
      expect(
        webSearchProviderRouteFor('SearXNG'),
        '/settings/web-search/searxng',
      );
      expect(
        webSearchProviderRouteFor('searxng', enableOnSave: true),
        '/settings/web-search/searxng?enable=1',
      );
      expect(
        settingsRouteForFailure(
          const AppFailure(
            kind: FailureKind.authentication,
            source: FailureSource(
              subsystem: AppSubsystem.webSearch,
              operation: 'search',
              providerId: 'SearXNG',
            ),
            message: 'Credentials were rejected.',
          ),
        ),
        '/settings/web-search/searxng',
      );
      expect(
        settingsRouteForFailure(
          const AppFailure(
            kind: FailureKind.authentication,
            source: FailureSource(
              subsystem: AppSubsystem.webSearch,
              operation: 'search',
              providerId: 'unknown',
            ),
            message: 'Credentials were rejected.',
          ),
        ),
        webSearchSettingsRoute,
      );
    },
  );

  testWidgets('settings navigation updates the route on mobile', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: App()));
    final BuildContext chatContext = tester.element(find.byType(ChatScreen));
    expect(GoRouter.of(chatContext).state.uri.path, homeRoute);

    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    BuildContext settingsContext = tester.element(find.byType(SettingsScreen));
    GoRouter router = GoRouter.of(settingsContext);
    expect(router.state.uri.path, settingsRoute);
    expect(router.routeInformationProvider.value.uri.path, settingsRoute);

    await tester.tap(find.text('Web search'));
    await tester.pumpAndSettle();

    settingsContext = tester.element(find.byType(SettingsScreen));
    router = GoRouter.of(settingsContext);
    expect(router.state.uri.path, settingsRouteFor(SettingsSection.webSearch));
    expect(
      router.routeInformationProvider.value.uri.path,
      settingsRouteFor(SettingsSection.webSearch),
    );
    expect(find.text('Search providers'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    settingsContext = tester.element(find.byType(SettingsScreen));
    router = GoRouter.of(settingsContext);
    expect(router.state.uri.path, settingsRoute);
    expect(router.routeInformationProvider.value.uri.path, settingsRoute);
    expect(find.text('Models & providers'), findsOneWidget);
  });

  testWidgets('direct settings routes resolve and invalid ones show an error', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final GoRouter router = createAppRouter(
      initialLocation: settingsRouteFor(SettingsSection.general),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/settings/general');
    expect(find.text('Show hidden models'), findsOneWidget);

    router.go('/settings/not-a-section');
    await tester.pumpAndSettle();

    expect(
      router.routeInformationProvider.value.uri.path,
      '/settings/not-a-section',
    );
    expect(find.textContaining('Unknown settings section'), findsOneWidget);
  });

  testWidgets('catalog navigation and details stay synchronized with routes', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final GoRouter router = createAppRouter(
      initialLocation: modelsCatalogRouteFor(PricingScope.models),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          modelsDevServiceProvider.overrideWithValue(_FakeModelsDevService()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.text('Canonical Model'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      router.state.uri.toString(),
      '/settings/models/models/model?id=test-lab%2Fcanonical-model',
    );
    expect(find.text('Pricing'), findsOneWidget);

    router.pop();
    await tester.pump();
    expect(router.state.uri.path, '/settings/models/models');

    await tester.tap(find.text('API providers'));
    await tester.pump();
    expect(router.state.uri.path, '/settings/models/providers');

    unawaited(router.push('/settings/models/providers/test-provider'));
    await tester.pump();
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(SettingsScreen)),
      ).read(pricingViewModelProvider).selectedGroupId,
      'test-provider',
    );

    router.pop();
    await tester.pump();
    expect(router.state.uri.path, '/settings/models/providers');
    expect(
      ProviderScope.containerOf(
        tester.element(find.byType(SettingsScreen)),
      ).read(pricingViewModelProvider).selectedGroupId,
      isNull,
    );

    await tester.tap(find.text('Model catalog'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/settings/models/models');
  });

  testWidgets('desktop settings root routes catalog tabs', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final GoRouter router = createAppRouter(initialLocation: settingsRoute);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          modelsDevServiceProvider.overrideWithValue(_FakeModelsDevService()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(router.state.uri.path, settingsRoute);
    await tester.tap(find.text('Model catalog'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/settings/models/models');
  });

  testWidgets('mobile catalog tabs replace the current settings route', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final GoRouter router = createAppRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          modelsDevServiceProvider.overrideWithValue(_FakeModelsDevService()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    unawaited(router.push<void>(settingsRoute));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Models & providers'));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/settings/models/providers');

    final State<StatefulWidget> settingsState = tester.state(
      find.byType(SettingsScreen),
    );
    await tester.tap(find.text('Models'));
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/settings/models/models');
    expect(
      tester.state<State<StatefulWidget>>(find.byType(SettingsScreen)),
      same(settingsState),
    );

    router.pop();
    await tester.pumpAndSettle();
    expect(router.state.uri.path, settingsRoute);

    router.pop();
    await tester.pumpAndSettle();
    expect(router.state.uri.path, homeRoute);
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('a direct model route restores the mobile detail sheet', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final GoRouter router = createAppRouter(
      initialLocation: modelsCatalogRouteFor(
        PricingScope.models,
        modelId: 'test-lab/canonical-model',
      ),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          modelsDevServiceProvider.overrideWithValue(_FakeModelsDevService()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Canonical Model'), findsWidgets);
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    expect(tester.takeException(), isNull);

    router.pop();
    await tester.pump();
    expect(router.state.uri.path, '/settings/models/models');
  });

  testWidgets('Poe callback errors return to the canonical accounts route', (
    WidgetTester tester,
  ) async {
    final String accountsRoute = modelsCatalogRouteFor(PricingScope.accounts);
    final GoRouter router = GoRouter(
      initialLocation: poeOAuthCallbackRoute,
      routes: <RouteBase>[
        GoRoute(
          path: poeOAuthCallbackRoute,
          builder: (BuildContext context, GoRouterState state) =>
              PoeOAuthCallbackScreen(
                callbackUri: state.uri,
                accountsRoute: accountsRoute,
              ),
        ),
        GoRoute(
          path: accountsRoute,
          builder: (BuildContext context, GoRouterState state) =>
              const Text('Accounts destination'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Back to accounts'));
    await tester.pumpAndSettle();

    expect(router.state.uri.path, accountsRoute);
    expect(find.text('Accounts destination'), findsOneWidget);
  });

  testWidgets('desktop section back returns to settings, not chat', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final GoRouter router = createAppRouter(
      initialLocation: settingsRouteFor(SettingsSection.webSearch),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/settings/web-search');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(router.state.uri.path, settingsRoute);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byType(ChatScreen), findsNothing);
  });

  testWidgets('chat selection and new chat stay synchronized with the route', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final Conversation conversation = Conversation(
      id: 'conversation-1',
      title: 'Routed conversation',
    );
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        conversationStoreProvider.overrideWithValue(
          _SeededConversationStore(conversation),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(conversationRepositoryProvider).ready;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const App(initialLocation: homeRoute),
      ),
    );
    await tester.pumpAndSettle();

    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('conversation-1')));
    await tester.pumpAndSettle();

    BuildContext chatContext = tester.element(find.byType(ChatScreen));
    expect(
      GoRouter.of(chatContext).state.uri.path,
      chatRouteFor(conversation.id),
    );
    expect(
      container.read(conversationRepositoryProvider).activeId,
      conversation.id,
    );

    tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Web search'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    chatContext = tester.element(find.byType(ChatScreen));
    expect(
      GoRouter.of(chatContext).state.uri.path,
      chatRouteFor(conversation.id),
    );

    await tester.tap(find.byTooltip('New chat'));
    await tester.pumpAndSettle();

    chatContext = tester.element(find.byType(ChatScreen));
    expect(GoRouter.of(chatContext).state.uri.path, homeRoute);
    expect(container.read(conversationRepositoryProvider).activeId, isNull);
  });

  testWidgets('direct chat routes select valid chats and reject missing ones', (
    WidgetTester tester,
  ) async {
    final Conversation conversation = Conversation(
      id: 'conversation-2',
      title: 'Direct conversation',
    );
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        conversationStoreProvider.overrideWithValue(
          _SeededConversationStore(conversation),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(conversationRepositoryProvider).ready;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: App(initialLocation: chatRouteFor(conversation.id)),
      ),
    );
    await tester.pumpAndSettle();

    BuildContext chatContext = tester.element(find.byType(ChatScreen));
    final GoRouter router = GoRouter.of(chatContext);
    expect(router.state.uri.path, chatRouteFor(conversation.id));
    expect(
      container.read(conversationRepositoryProvider).activeId,
      conversation.id,
    );

    router.go('/chat/missing-conversation');
    await tester.pumpAndSettle();

    chatContext = tester.element(find.byType(ChatScreen));
    expect(GoRouter.of(chatContext).state.uri.path, homeRoute);
    expect(container.read(conversationRepositoryProvider).activeId, isNull);
  });

  testWidgets('provider configuration is a deep-linkable modal route', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final GoRouter router = createAppRouter(
      initialLocation: webSearchProviderRouteFor('searxng'),
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/settings/web-search/searxng');
    expect(
      router.routeInformationProvider.value.uri.path,
      '/settings/web-search/searxng',
    );
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Configure SearXNG'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(router.state.uri.path, webSearchSettingsRoute);
    expect(find.text('Configure SearXNG'), findsNothing);
    expect(find.text('Search providers'), findsOneWidget);
  });

  testWidgets('provider tiles open their URL-backed configuration modal', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final GoRouter router = createAppRouter(
      initialLocation: webSearchSettingsRoute,
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('SearXNG'));
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/settings/web-search/searxng');
    expect(
      router.routeInformationProvider.value.uri.path,
      '/settings/web-search/searxng',
    );
    expect(find.text('Configure SearXNG'), findsOneWidget);
  });

  testWidgets('opening a provider from chat layers settings under the modal', (
    WidgetTester tester,
  ) async {
    final GoRouter router = createAppRouter(initialLocation: homeRoute);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();

    final BuildContext chatContext = tester.element(find.byType(ChatScreen));
    await openSettingsForFailure(
      chatContext,
      const AppFailure(
        kind: FailureKind.authentication,
        source: FailureSource(
          subsystem: AppSubsystem.webSearch,
          operation: 'search',
          providerId: 'SearXNG',
        ),
        message: 'Credentials were rejected.',
      ),
    );
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/settings/web-search/searxng');
    expect(
      router.routeInformationProvider.value.uri.path,
      '/settings/web-search/searxng',
    );
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Configure SearXNG'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(router.state.uri.path, webSearchSettingsRoute);
    expect(
      router.routeInformationProvider.value.uri.path,
      webSearchSettingsRoute,
    );
    expect(find.byType(SettingsScreen), findsOneWidget);
  });
}

class _FakeModelsDevService extends ModelsDevService {
  _FakeModelsDevService()
    : _catalog = ModelsCatalog.fromCatalogJson(<String, Object?>{
        'models': <String, Object?>{
          'test-lab/canonical-model': <String, Object?>{
            'id': 'test-lab/canonical-model',
            'name': 'Canonical Model',
          },
        },
        'providers': <String, Object?>{},
      }, fetchedAt: DateTime(2026));

  final ModelsCatalog _catalog;

  @override
  Future<ModelsCatalog> load({bool forceRefresh = false}) async => _catalog;

  @override
  Future<ModelsCatalog> refresh() async => _catalog;
}

class _SeededConversationStore implements ConversationStore {
  _SeededConversationStore(this.conversation);

  final Conversation conversation;

  @override
  Future<List<Conversation>> load() async => <Conversation>[conversation];

  @override
  Future<void> upsert(Conversation conversation) async {}

  @override
  Future<void> delete(String id) async {}
}
