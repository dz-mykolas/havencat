import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/services/auth/secret_store.dart';
import 'data/services/llm/account_models_service.dart';
import 'data/services/pricing/models_dev_service.dart';
import 'data/services/storage/account_store.dart';
import 'data/services/storage/app_settings.dart';
import 'data/services/web_retrieval/rust_web_retrieval_adapter.dart';
import 'domain/models/provider_account.dart';
import 'providers.dart';
import 'server/app_config.dart';
import 'server/logging.dart';
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

  // On native, configure the Rust web_retrieval module (SQLite cache + provider
  // slots) before any search/fetch calls. On web this is a no-op — the
  // HttpWebRetrievalAdapter talks to the local server instead.
  //
  // Default providers are always enabled so the toggle in the chat input
  // works out of the box. Custom per-provider configuration can come later.
  if (!kIsWeb) {
    final RustWebRetrievalAdapter adapter =
        container.read(webRetrievalProvider) as RustWebRetrievalAdapter;
    await adapter.configure(
      dbPath: '',
      searchProviders: const <ProviderSlotConfig>[
        ProviderSlotConfig(kind: 'searxng'),
        ProviderSlotConfig(kind: 'exa'),
      ],
      fetchProviders: const <ProviderSlotConfig>[
        ProviderSlotConfig(kind: 'direct_http'),
        ProviderSlotConfig(kind: 'jina_reader'),
      ],
    );
  }

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
