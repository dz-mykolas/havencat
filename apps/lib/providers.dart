import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/repositories/conversation_repository.dart';
import 'data/repositories/provider_account_repository.dart';
import 'data/services/auth/chatgpt_oauth_flow.dart';
import 'data/services/auth/chatgpt_token_service.dart';
import 'data/services/auth/credential_resolver.dart';
import 'data/services/auth/secret_store.dart';
import 'data/services/llm/adapter_registry.dart';
import 'data/services/storage/account_store.dart';
import 'data/services/storage/app_settings.dart';

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

/// Single shared [AdapterRegistry]. Adapters are stateless so one instance
/// per kind is fine.
final adapterRegistryProvider = Provider<AdapterRegistry>((ref) {
  return AdapterRegistry();
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

/// Source of truth for conversations + the streaming reply flow.
final conversationRepositoryProvider =
    ChangeNotifierProvider<ConversationRepository>((ref) {
      return ConversationRepository(
        providerRepository: ref.watch(providerAccountRepositoryProvider),
        adapterRegistry: ref.watch(adapterRegistryProvider),
        credentialResolver: ref.watch(credentialResolverProvider),
      );
    });
