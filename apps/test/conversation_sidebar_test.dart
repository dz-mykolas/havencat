import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/data/repositories/conversation_repository.dart';
import 'package:app/data/repositories/provider_account_repository.dart';
import 'package:app/data/services/auth/chatgpt_oauth_flow.dart';
import 'package:app/data/services/auth/chatgpt_token_service.dart';
import 'package:app/data/services/auth/credential_resolver.dart';
import 'package:app/data/services/auth/secret_store.dart';
import 'package:app/data/services/llm/adapter_registry.dart';
import 'package:app/data/services/storage/account_store.dart';
import 'package:app/data/services/storage/conversation_store.dart';
import 'package:app/domain/models/app_theme_preferences.dart';
import 'package:app/domain/models/conversation.dart';
import 'package:app/domain/models/message.dart';
import 'package:app/ui/chat/chat_viewmodel.dart';
import 'package:app/ui/chat/widgets/conversation_drawer.dart';
import 'package:app/ui/core/theme/app_theme.dart';

void main() {
  testWidgets('desktop brand mark indicates on hover and expands on click', (
    WidgetTester tester,
  ) async {
    final _TestChat chat = _TestChat();
    addTearDown(chat.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppThemePreset.haven),
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerLeft,
            child: ConversationSidebar(viewModel: chat.viewModel),
          ),
        ),
      ),
    );

    expect(find.text('HavenCat'), findsOneWidget);
    expect(
      DefaultTextStyle.of(
        tester.element(find.text('HavenCat')),
      ).style.decoration,
      isNot(TextDecoration.underline),
    );
    await tester.tap(find.byTooltip('Collapse sidebar'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Expand sidebar'), findsOneWidget);
    expect(
      tester.getSize(find.byType(ConversationSidebar)).width,
      ConversationSidebar.railWidth,
    );

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(
      location: tester.getCenter(find.byTooltip('Expand sidebar')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byIcon(Icons.keyboard_double_arrow_right_rounded),
      findsOneWidget,
    );
    expect(find.byTooltip('Expand sidebar'), findsOneWidget);

    await tester.tap(find.byTooltip('Expand sidebar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final double openingWidth = tester
        .getSize(find.byType(ConversationSidebar))
        .width;
    expect(openingWidth, greaterThan(ConversationSidebar.railWidth));
    expect(openingWidth, lessThan(ConversationSidebar.expandedWidth));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Collapse sidebar'), findsOneWidget);
    expect(find.text('HavenCat'), findsOneWidget);
    expect(
      tester.getSize(find.byType(ConversationSidebar)).width,
      ConversationSidebar.expandedWidth,
    );
    await mouse.removePointer();
  });

  testWidgets('new chat selection and sidebar brand share the home action', (
    WidgetTester tester,
  ) async {
    final _TestChat chat = _TestChat(
      conversations: <Conversation>[_conversation('first', 'First chat')],
    );
    addTearDown(chat.dispose);
    bool homeInvoked = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppThemePreset.haven),
        home: Scaffold(
          body: ConversationSidebar(
            viewModel: chat.viewModel,
            collapsible: false,
            onNewChat: () {
              homeInvoked = true;
              chat.viewModel.newConversation();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Current'), findsNothing);
    await tester.tap(find.text('First chat'));
    await tester.pumpAndSettle();
    expect(find.text('Current'), findsNothing);

    await tester.tap(find.text('HavenCat'));
    await tester.pumpAndSettle();
    expect(homeInvoked, isTrue);
    expect(find.text('Current'), findsNothing);
  });

  testWidgets('theme icon and settings action share the sidebar footer', (
    WidgetTester tester,
  ) async {
    final _TestChat chat = _TestChat();
    addTearDown(chat.dispose);
    bool themeToggled = false;
    bool settingsOpened = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppThemePreset.haven),
        home: Scaffold(
          body: ConversationSidebar(
            viewModel: chat.viewModel,
            collapsible: false,
            themeSlot: AppThemeSlot.dark,
            onToggleTheme: () => themeToggled = true,
            onOpenSettings: () => settingsOpened = true,
          ),
        ),
      ),
    );

    expect(find.text('Settings'), findsOneWidget);
    final Finder themeToggle = find.byKey(
      const ValueKey<String>('sidebar-theme-toggle'),
    );
    expect(themeToggle, findsOneWidget);
    expect(tester.getSize(themeToggle), const Size.square(40));
    expect(find.byTooltip('Use light theme'), findsOneWidget);

    await tester.tap(themeToggle);
    await tester.tap(find.text('Settings'));

    expect(themeToggled, isTrue);
    expect(settingsOpened, isTrue);
  });

  testWidgets('search expands beside new chat and filters in place', (
    WidgetTester tester,
  ) async {
    final _TestChat chat = _TestChat(
      conversations: <Conversation>[
        _conversation('first', 'First chat'),
        _conversation('second', 'Second chat'),
      ],
    );
    addTearDown(chat.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppThemePreset.haven),
        home: Scaffold(
          body: ConversationSidebar(
            viewModel: chat.viewModel,
            collapsible: false,
          ),
        ),
      ),
    );
    await tester.pump();

    final Finder newChat = find.byKey(
      const ValueKey<String>('sidebar-new-chat'),
    );
    final Finder search = find.byKey(
      const ValueKey<String>('sidebar-chat-search'),
    );
    final double initialNewChatWidth = tester.getSize(newChat).width;
    final double initialSearchWidth = tester.getSize(search).width;

    await tester.tap(find.byTooltip('Search chats'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getSize(newChat).width, lessThan(initialNewChatWidth));
    expect(tester.getSize(search).width, greaterThan(initialSearchWidth));
    await tester.pumpAndSettle();
    expect(tester.getSize(newChat).width, 44);
    expect(tester.getSize(search).width, initialNewChatWidth);
    expect(
      tester.getCenter(find.text('Search chats')).dy,
      closeTo(tester.getCenter(search).dy, 0.5),
    );
    final InputDecoration searchDecoration = tester
        .widget<TextField>(find.byType(TextField))
        .decoration!;
    expect(searchDecoration.filled, isFalse);
    expect(searchDecoration.focusedBorder, InputBorder.none);

    await tester.enterText(find.byType(TextField), 'Second');
    await tester.pump();
    expect(find.text('First chat'), findsNothing);
    expect(find.text('Second chat'), findsOneWidget);

    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('First chat'), findsOneWidget);
  });

  testWidgets('opening search keeps empty state vertically stable', (
    WidgetTester tester,
  ) async {
    final _TestChat chat = _TestChat();
    addTearDown(chat.dispose);

    Future<void> pumpSidebar({required bool keyboardOpen}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(AppThemePreset.haven),
          home: MediaQuery(
            data: MediaQueryData(
              padding: EdgeInsets.only(bottom: keyboardOpen ? 0 : 24),
              viewPadding: const EdgeInsets.only(bottom: 24),
              viewInsets: EdgeInsets.only(bottom: keyboardOpen ? 300 : 0),
            ),
            child: Material(
              child: ConversationSidebar(
                viewModel: chat.viewModel,
                collapsible: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await pumpSidebar(keyboardOpen: false);
    final Finder emptyState = find.text('No conversations yet');
    final double initialY = tester.getCenter(emptyState).dy;

    await tester.tap(find.byTooltip('Search chats'));
    await tester.pumpAndSettle();
    expect(tester.getCenter(emptyState).dy, closeTo(initialY, 0.01));

    await pumpSidebar(keyboardOpen: true);
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.getCenter(emptyState).dy, closeTo(initialY, 0.01));
  });

  testWidgets('desktop chat actions appear only while the row is hovered', (
    WidgetTester tester,
  ) async {
    final _TestChat chat = _TestChat(
      conversations: <Conversation>[_conversation('first', 'First chat')],
    );
    addTearDown(chat.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(
          AppThemePreset.haven,
        ).copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: ConversationSidebar(
            viewModel: chat.viewModel,
            collapsible: false,
          ),
        ),
      ),
    );
    await tester.pump();

    Opacity actionsOpacity() => tester.widget<Opacity>(
      find.ancestor(
        of: find.byTooltip('Chat actions'),
        matching: find.byType(Opacity),
      ),
    );

    expect(actionsOpacity().opacity, 0);
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: tester.getCenter(find.text('First chat')));
    await tester.pumpAndSettle();
    expect(actionsOpacity().opacity, 1);
    expect(
      tester.getCenter(find.byTooltip('Pin chat')).dx,
      lessThan(tester.getCenter(find.byTooltip('Chat actions')).dx),
    );

    await tester.tap(find.byTooltip('Chat actions'));
    await tester.pump();
    expect(actionsOpacity().opacity, 1);
    expect(find.text('Export'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Pin chat'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Export')).dy,
      lessThan(tester.getTopLeft(find.text('Rename')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Rename')).dy,
      lessThan(tester.getTopLeft(find.text('Pin chat')).dy),
    );
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await mouse.removePointer();
  });

  testWidgets('touch long-press opens actions and pinning moves a chat first', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final _TestChat chat = _TestChat(
      conversations: <Conversation>[
        _conversation('first', 'First chat'),
        _conversation('second', 'Second chat'),
      ],
    );
    addTearDown(chat.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(
          AppThemePreset.haven,
        ).copyWith(platform: TargetPlatform.android),
        home: Scaffold(
          body: ConversationSidebar(
            viewModel: chat.viewModel,
            collapsible: false,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(BottomSheet), findsNothing);
    await tester.longPress(find.text('Second chat'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Pin'), findsOneWidget);

    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Second chat')).dy,
      lessThan(tester.getTopLeft(find.text('First chat')).dy),
    );
    expect(chat.store.lastUpsert?.id, 'second');
    expect(chat.store.lastUpsert?.isPinned, isTrue);

    await tester.longPress(find.text('Second chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(TextFormField), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'Renamed chat');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Renamed chat'), findsOneWidget);
  });

  testWidgets('mobile drawer opens from a drag anywhere on screen', (
    WidgetTester tester,
  ) async {
    final _TestChat chat = _TestChat();
    addTearDown(chat.dispose);
    final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppThemePreset.haven),
        home: Scaffold(
          key: scaffoldKey,
          drawerEnableOpenDragGesture: true,
          drawerEdgeDragWidth: 800,
          drawer: ConversationDrawer(viewModel: chat.viewModel),
          body: const SizedBox.expand(),
        ),
      ),
    );

    expect(scaffoldKey.currentState!.isDrawerOpen, isFalse);
    await tester.dragFrom(const Offset(400, 300), const Offset(260, 0));
    await tester.pumpAndSettle();
    expect(scaffoldKey.currentState!.isDrawerOpen, isTrue);
  });
}

Conversation _conversation(String id, String title) {
  return Conversation(
    id: id,
    title: title,
    messages: <ChatMessage>[
      ChatMessage(id: '${id}_message', role: MessageRole.user, text: title),
    ],
  );
}

class _TestChat {
  _TestChat({List<Conversation> conversations = const <Conversation>[]}) {
    final SecretStore secrets = SecretStore();
    providers = ProviderAccountRepository(
      accountStore: AccountStore(),
      secretStore: secrets,
    );
    final ChatGptOAuthFlow oauth = ChatGptOAuthFlow(
      clientId: 'test',
      issuer: 'https://auth.test',
    );
    final ChatGptTokenService tokens = ChatGptTokenService(
      secretStore: secrets,
      oauthFlow: oauth,
    );
    store = _TestConversationStore(conversations);
    repository = ConversationRepository(
      providerRepository: providers,
      adapterRegistry: AdapterRegistry(),
      credentialResolver: CredentialResolver(
        secretStore: secrets,
        chatGptTokens: tokens,
      ),
      conversationStore: store,
    );
    viewModel = ChatViewModel(repository, providers);
  }

  late final ProviderAccountRepository providers;
  late final _TestConversationStore store;
  late final ConversationRepository repository;
  late final ChatViewModel viewModel;

  void dispose() {
    viewModel.dispose();
    repository.dispose();
    providers.dispose();
  }
}

class _TestConversationStore implements ConversationStore {
  _TestConversationStore(this.conversations);

  final List<Conversation> conversations;
  Conversation? lastUpsert;

  @override
  Future<List<Conversation>> load() async => conversations;

  @override
  Future<void> upsert(Conversation conversation) async {
    lastUpsert = conversation;
  }

  @override
  Future<void> delete(String id) async {}
}
