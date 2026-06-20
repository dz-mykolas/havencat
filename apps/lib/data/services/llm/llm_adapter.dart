import '../../../domain/models/adapter_kind.dart';
import '../../../domain/models/llm_model.dart';
import '../../../domain/models/provider_account.dart';
import 'llm_event.dart';

/// A stateless service that turns an [LlmRequest] into a stream of [LlmEvent]s.
///
/// One implementation per adapter family (mock, OpenAI-compatible,
/// Anthropic, Gemini-native, subscription OAuth flows, future on-device).
/// The repository picks the right adapter for the active [ProviderAccount]
/// and pipes its events to the view model.
///
/// Adapters must NOT hold state between calls. Auth tokens, base URLs, model
/// ids — all come in via [ProviderAccount.config] + the resolved secret.
abstract class LlmAdapter {
  /// Which family this adapter implements.
  AdapterKind get kind;

  /// Stream the assistant reply for [request] using [account]'s config and
  /// the resolved [secret] (API key or OAuth access token; null for mock /
  /// on-device adapters).
  ///
  /// The stream must emit one terminal event — either [DoneEvent] or
  /// [ErrorEvent] — and then close. Adapters should not emit after a terminal.
  Stream<LlmEvent> stream({
    required LlmRequest request,
    required ProviderAccount account,
    required String? secret,
  });

  /// Fetches the models [account] can use, straight from the provider (no
  /// hardcoded lists). Used to populate the model picker; the default selection
  /// is chosen from whatever this returns.
  ///
  /// May throw on network/auth failure — callers surface that as a retryable
  /// error rather than guessing a model.
  Future<List<LlmModel>> listModels({
    required ProviderAccount account,
    required String? secret,
  });
}
