import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/services/auth/secret_store.dart';
import 'data/services/llm/account_models_service.dart';
import 'data/services/pricing/models_dev_service.dart';
import 'data/services/storage/account_store.dart';
import 'data/services/storage/app_settings.dart';
import 'domain/models/provider_account.dart';
import 'providers.dart';
import 'server/app_config.dart';
import 'server/logging.dart';
import 'src/rust/api/conversations.dart' as rust_conversations;
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final AppConfig config = AppConfig.load();
  initLogging(level: config.logLevel);

  // FRB loads the native library via FFI. On web there's no FFI — the web
  // build uses HttpWebRetrievalAdapter (HTTP to the local server) instead of
  // RustWebRetrievalAdapter (FRB FFI). So skip init on web.
  if (!kIsWeb) {
    await RustLib.init();
  }

  // Initialize real, platform-backed storage and restore the saved session
  // (accounts + active id) before the first frame, so a restart / browser
  // refresh keeps the user signed in. Secrets stay in secure storage; only
  // non-secret metadata lives in SharedPreferences.
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final AccountStore accountStore = AccountStore(prefs: prefs);
  final SecretStore secretStore = SecretStore.secure();

  final ProviderContainer container = ProviderContainer(
    overrides: <Override>[
      accountStoreProvider.overrideWithValue(accountStore),
      secretStoreProvider.overrideWithValue(secretStore),
      appSettingsProvider.overrideWith((_) => AppSettings(prefs: prefs)),
      sharedPreferencesProvider.overrideWithValue(prefs),
      modelsDevServiceProvider.overrideWithValue(ModelsDevService()),
    ],
  );
  await container.read(providerAccountRepositoryProvider).load();

  // Configure native conversation persistence before repositories use it.
  if (!kIsWeb) {
    // Configure the conversations SQLite database. On native the DB file
    // lives in the app's support directory (persistent, not user-visible,
    // auto-created by path_provider).
    final String convDbPath =
        '${(await getApplicationSupportDirectory()).path}/conversations.db';
    await rust_conversations.configureConversations(dbPath: convDbPath);
  }

  final backgroundController = container.read(
    generationBackgroundServiceProvider,
  );
  await backgroundController.initialize();
  final conversationRepository = container.read(conversationRepositoryProvider);
  await conversationRepository.ready;
  backgroundController.onConversationSelected =
      conversationRepository.selectConversation;
  final String? notificationConversation = backgroundController
      .takeSelectedConversation();
  if (notificationConversation != null) {
    conversationRepository.selectConversation(notificationConversation);
  }

  // Provider choices and credentials come from in-app settings. On native
  // this configures Rust directly; on web it configures the local server.
  await container.read(webSearchSettingsProvider).initialize();

  // Pre-warm the models.dev catalog in the background so the pricing browser
  // (Settings -> Discover) opens to ready data instead of a spinner. This is
  // fire-and-forget: it never blocks first-frame, and failures (e.g. offline)
  // are swallowed here and surfaced lazily inside the pricing screen instead.
  unawaited(container.read(modelsDevServiceProvider).load());

  // Pre-warm the per-account model lists (from each provider's own /models
  // endpoint) so the chat header's model picker is populated before the user
  // opens a conversation — same fire-and-forget pattern as the catalog. Also
  // loads any cached results from disk first so they're available offline.
  unawaited(_warmAccountModels(container));

  runApp(UncontrolledProviderScope(container: container, child: const App()));
}

/// Loads cached per-account model lists from disk, then kicks off a network
/// refresh for every configured account. Fire-and-forget — failures are
/// swallowed here and surfaced lazily via [AccountModelsService.errorFor]
/// when the chat header reads the cache.
Future<void> _warmAccountModels(ProviderContainer container) async {
  final AccountModelsService service = container.read(
    accountModelsServiceProvider,
  );
  final List<ProviderAccount> accounts = container
      .read(providerAccountRepositoryProvider)
      .accounts;
  // Load cached results first so they're available immediately (offline /
  // before the network lands), then refresh from the network.
  for (final ProviderAccount a in accounts) {
    await service.loadCached(a.id);
  }
  await service.warmAll();
}
