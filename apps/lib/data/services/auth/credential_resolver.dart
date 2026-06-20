import '../../../domain/models/adapter_kind.dart';
import '../../../domain/models/provider_account.dart';
import 'chatgpt_token_service.dart';
import 'secret_store.dart';

/// Resolves the secret an [LlmAdapter] needs for a given account, hiding *how*
/// that secret is produced from the rest of the app.
///
///   * mock            → no secret.
///   * subscription    → a *valid* OAuth access token, refreshed on demand by
///                       [ChatGptTokenService].
///   * everything else → the raw API key from secure storage.
///
/// This is the single seam the conversation flow goes through, so token
/// refresh "just happens" the moment a message is sent after a restart.
class CredentialResolver {
  CredentialResolver({
    required this._secretStore,
    required this._chatGptTokens,
  });

  final SecretStore _secretStore;
  final ChatGptTokenService _chatGptTokens;

  Future<String?> resolve(ProviderAccount account) {
    switch (account.kind) {
      case AdapterKind.mock:
        return Future<String?>.value(null);
      case AdapterKind.subscription:
        return _chatGptTokens.validAccessToken(account.id);
      case AdapterKind.openaiCompatible:
      case AdapterKind.anthropic:
      case AdapterKind.geminiNative:
      case AdapterKind.onDevice:
        return _secretStore.read(account.id);
    }
  }
}
