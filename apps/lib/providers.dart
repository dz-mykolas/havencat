import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/repositories/conversation_repository.dart';
import 'data/repositories/provider_account_repository.dart';
import 'data/services/auth/chatgpt_oauth_flow.dart';
import 'data/services/auth/chatgpt_token_service.dart';
import 'data/services/auth/credential_resolver.dart';
import 'data/services/auth/secret_store.dart';
import 'data/services/llm/account_models_service.dart';
import 'data/services/llm/adapter_registry.dart';
import 'data/services/llm/model_service.dart';
import 'data/services/pricing/models_dev_service.dart';
import 'data/services/storage/account_store.dart';
import 'data/services/storage/app_settings.dart';
import 'data/services/web_retrieval/http_web_retrieval_adapter.dart';
import 'data/services/web_retrieval/rust_web_retrieval_adapter.dart';
import 'data/services/web_retrieval/web_retrieval.dart';

/// Secure storage for secrets (API keys + OAuth token bundles).
///
/// Default is an in-memory [SecretStore] so widget tests run without the
/// platform plugin. `main()` overrides this with [SecretStore.secure] so real
/// device/browser storage is used in the running app.
final secretStoreProvider = Provider<SecretStore>((ref) {
  return SecretStore();
});

/// Persistence for non-secret account metadata (the account list + active id).
///
/// Default is in-memory (tests). `main()` overrides this with a
/// `SharedPreferences`-backed [AccountStore].
final accountStoreProvider = Provider<AccountStore>((ref) {
  return AccountStore();
});

/// Global app preferences (e.g. "show hidden models").
///
/// Default is in-memory (tests). `main()` overrides this with a
/// `SharedPreferences`-backed instance.
final appSettingsProvider = ChangeNotifierProvider<AppSettings>((ref) {
  return AppSettings();
});

/// Shared `SharedPreferences` instance. Default is null (tests / first run);
/// `main()` overrides this with the real platform-backed instance so services
/// like [AccountModelsService] can persist their caches across restarts.
final sharedPreferencesProvider = Provider<SharedPreferences?>((ref) {
  return null;
});

/// Single shared [AdapterRegistry]. Adapters are stateless so one instance
/// per kind is fine.
final adapterRegistryProvider = Provider<AdapterRegistry>((ref) {
  return AdapterRegistry();
});

/// Public model database (pricing + capabilities) from models.dev.
///
/// Default has no persistence (tests / first run). `main()` overrides this with
/// a `SharedPreferences`-backed instance so the catalog is cached across
/// restarts and available offline.
final modelsDevServiceProvider = Provider<ModelsDevService>((ref) {
  return ModelsDevService();
});

/// ChatGPT OAuth device-code flow. One instance for the whole app.
final chatGptOAuthFlowProvider = Provider<ChatGptOAuthFlow>((ref) {
  return ChatGptOAuthFlow();
});

/// Manages the ChatGPT subscription token lifecycle (refresh + revoke).
final chatGptTokenServiceProvider = Provider<ChatGptTokenService>((ref) {
  return ChatGptTokenService(
    secretStore: ref.watch(secretStoreProvider),
    oauthFlow: ref.watch(chatGptOAuthFlowProvider),
  );
});

/// Resolves a ready-to-use secret (refreshed access token / raw API key) for
/// an account. The conversation flow goes through this.
final credentialResolverProvider = Provider<CredentialResolver>((ref) {
  return CredentialResolver(
    secretStore: ref.watch(secretStoreProvider),
    chatGptTokens: ref.watch(chatGptTokenServiceProvider),
  );
});

/// Source of truth for configured provider accounts + the active one.
///
/// `main()` calls [ProviderAccountRepository.load] on this instance before the
/// first frame so persisted accounts are restored without a flash.
final providerAccountRepositoryProvider =
    ChangeNotifierProvider<ProviderAccountRepository>((ref) {
      return ProviderAccountRepository(
        accountStore: ref.watch(accountStoreProvider),
        secretStore: ref.watch(secretStoreProvider),
      );
    });

/// Caches the models each configured account exposes, fetched from the
/// provider's own "list models" endpoint. Pre-warmed on startup (like
/// [modelsDevServiceProvider]) so the chat header's model picker is
/// populated before the user opens a conversation.
///
/// Default has no persistence (tests). `main()` overrides this with a
/// `SharedPreferences`-backed instance.
final accountModelsServiceProvider =
    ChangeNotifierProvider<AccountModelsService>((ref) {
      return AccountModelsService(
        prefs: ref.watch(sharedPreferencesProvider),
        providers: ref.watch(providerAccountRepositoryProvider),
        adapters: ref.watch(adapterRegistryProvider),
        credentials: ref.watch(credentialResolverProvider),
      );
    });

/// Fetches models for a single account on demand. Used directly by tests and
/// by [AccountModelsService] internally; the chat UI goes through
/// [accountModelsServiceProvider] (the cached, pre-warmed path) instead.
final modelServiceProvider = Provider<ModelService>((ref) {
  return ModelService(
    adapters: ref.watch(adapterRegistryProvider),
    credentials: ref.watch(credentialResolverProvider),
  );
});

/// Source of truth for conversations + the streaming reply flow.
final conversationRepositoryProvider =
    ChangeNotifierProvider<ConversationRepository>((ref) {
      final WebRetrievalAdapter? webRetrieval = ref.watch(webRetrievalProvider);
      return ConversationRepository(
        providerRepository: ref.watch(providerAccountRepositoryProvider),
        adapterRegistry: ref.watch(adapterRegistryProvider),
        credentialResolver: ref.watch(credentialResolverProvider),
        webRetrieval: webRetrieval,
        // ref.read (not ref.watch) so toggling doesn't recreate the repository
        // and wipe conversations. The chat screen syncs the flag at runtime
        // via the toolsEnabled setter.
        toolsEnabled: ref.read(toolsEnabledProvider),
      );
    });

/// The web retrieval backend. On native (mobile/desktop) this is a
/// [RustWebRetrievalAdapter] calling Rust via FRB FFI directly. On web it's an
/// [HttpWebRetrievalAdapter] that calls the local server's `/api/*` JSON
/// routes (the server itself uses [RustWebRetrievalAdapter] under the hood, so
/// the same Rust crate backs both paths).
///
/// `main()` calls `configure()` on the native adapter at startup; tests can
/// override this provider with a mock.
final webRetrievalProvider = Provider<WebRetrievalAdapter>((ref) {
  if (kIsWeb) {
    return HttpWebRetrievalAdapter();
  }
  return RustWebRetrievalAdapter();
});

/// Whether tools (web search/fetch, etc.) are attached to outgoing chat
/// messages. Toggled from the chat input's "+" menu. Persists across rebuilds
/// (StateProvider); custom per-tool configuration can come later.
final toolsEnabledProvider = StateProvider<bool>((ref) => false);
