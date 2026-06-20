import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/repositories/conversation_repository.dart';
import 'data/repositories/provider_account_repository.dart';
import 'data/services/auth/chatgpt_oauth_flow.dart';
import 'data/services/auth/secret_store.dart';
import 'data/services/llm/adapter_registry.dart';

/// Single shared [SecretStore] for the whole app.
final secretStoreProvider = Provider<SecretStore>((ref) {
  return SecretStore();
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

/// Source of truth for configured provider accounts + the active one.
final providerAccountRepositoryProvider =
    ChangeNotifierProvider<ProviderAccountRepository>((ref) {
      return ProviderAccountRepository(
        secretStore: ref.watch(secretStoreProvider),
      );
    });

/// Source of truth for conversations + the streaming reply flow.
final conversationRepositoryProvider =
    ChangeNotifierProvider<ConversationRepository>((ref) {
      return ConversationRepository(
        providerRepository: ref.watch(providerAccountRepositoryProvider),
        adapterRegistry: ref.watch(adapterRegistryProvider),
        secretStore: ref.watch(secretStoreProvider),
      );
    });
