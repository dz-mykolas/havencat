import '../../../domain/models/adapter_kind.dart';
import '../../../domain/errors/app_failure.dart';
import '../../../domain/models/provider_account.dart';
import 'chatgpt_token_service.dart';
import 'secret_store.dart';

/// Resolves the secret an [LlmAdapter] needs for a given account, hiding *how*
/// that secret is produced from the rest of the app.
///
///   * mock            → no secret.
///   * chatGptCodex    → a *valid* OAuth access token, refreshed on demand by
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
      case AdapterKind.chatGptCodex:
        return _chatGptTokens.validAccessToken(account.id);
      case AdapterKind.openaiCompatible:
        if (account.config['definitionId'] == 'poe_subscription') {
          final FailureSource source = FailureSource(
            subsystem: AppSubsystem.authentication,
            operation: 'resolve_credentials',
            providerId: 'poe',
            accountId: account.id,
          );
          final Object? storedExpiry = account.config['credentialExpiresAt'];
          DateTime? expiresAt;
          if (storedExpiry != null) {
            if (storedExpiry is! String ||
                (expiresAt = DateTime.tryParse(storedExpiry)) == null) {
              return Future<String?>.error(
                AuthError(
                  'The saved Poe credential expiry is invalid. Reconnect Poe.',
                  source: source,
                ),
              );
            }
          }
          if (expiresAt != null && !DateTime.now().isBefore(expiresAt)) {
            return Future<String?>.error(
              AuthError(
                'Your Poe connection has expired. Reconnect Poe to continue.',
                source: source,
              ),
            );
          }
        }
        return _secretStore.read(account.id);
      case AdapterKind.anthropic:
      case AdapterKind.geminiNative:
      case AdapterKind.onDevice:
        return _secretStore.read(account.id);
    }
  }
}
