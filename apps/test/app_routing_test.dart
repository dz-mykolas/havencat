import 'package:app/app.dart';
import 'package:app/app_router.dart';
import 'package:app/data/services/storage/conversation_store.dart';
import 'package:app/domain/errors/app_failure.dart';
import 'package:app/domain/models/conversation.dart';
import 'package:app/providers.dart';
import 'package:app/ui/chat/chat_screen.dart';
import 'package:app/ui/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  test('settings sections have stable, reversible route segments', () {
    for (final SettingsSection section in SettingsSection.values) {
      expect(settingsSectionFromRoute(section.routeSegment), section);
      expect(settingsRouteFor(section), '/settings/${section.routeSegment}');
    }
    expect(settingsRouteFor(null), settingsRoute);
    expect(settingsSectionFromRoute('unknown'), isNull);
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

  testWidgets('direct and invalid settings routes resolve correctly', (
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

    expect(router.state.uri.path, settingsRoute);
    expect(find.text('Models & providers'), findsOneWidget);
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
