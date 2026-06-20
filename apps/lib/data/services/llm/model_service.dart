import '../../../domain/models/llm_model.dart';
import '../../../domain/models/provider_account.dart';
import '../auth/credential_resolver.dart';
import 'adapter_registry.dart';
import 'llm_adapter.dart';

/// Fetches the available models for a provider account.
///
/// Resolves the right adapter for the account's kind and the credential it
/// needs (refreshed OAuth token / API key) via [CredentialResolver], then asks
/// the adapter for its model list. On web this transparently goes through the
/// bundled proxy, like every other provider call.
class ModelService {
  ModelService({required this._adapters, required this._credentials});

  final AdapterRegistry _adapters;
  final CredentialResolver _credentials;

  Future<List<LlmModel>> list(ProviderAccount account) async {
    final LlmAdapter adapter = _adapters.resolve(account.kind);
    final String? secret = await _credentials.resolve(account);
    return adapter.listModels(account: account, secret: secret);
  }
}
