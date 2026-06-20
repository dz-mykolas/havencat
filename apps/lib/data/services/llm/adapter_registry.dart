import '../../../domain/models/adapter_kind.dart';
import 'llm_adapter.dart';
import 'mock/mock_llm_adapter.dart';
import 'openai_compatible/openai_compatible_adapter.dart';
import 'subscription/chatgpt_subscription_adapter.dart';

/// Maps an [AdapterKind] to a singleton [LlmAdapter] implementation.
///
/// Adapters are stateless, so one instance per kind is fine. The repository
/// looks up the adapter for a [ProviderAccount]'s kind here.
class AdapterRegistry {
  AdapterRegistry() {
    _adapters[AdapterKind.mock] = MockLlmAdapter();
    _adapters[AdapterKind.openaiCompatible] = OpenAiCompatibleAdapter();
    _adapters[AdapterKind.subscription] = ChatGptSubscriptionAdapter();
  }

  final Map<AdapterKind, LlmAdapter> _adapters = <AdapterKind, LlmAdapter>{};

  /// Register or override an adapter for [kind]. Used for tests and for
  /// future native/subscription adapters that need injected Dio instances.
  void register(AdapterKind kind, LlmAdapter adapter) {
    _adapters[kind] = adapter;
  }

  /// Returns the adapter for [kind], throwing [StateError] if none registered.
  LlmAdapter resolve(AdapterKind kind) {
    final LlmAdapter? adapter = _adapters[kind];
    if (adapter == null) {
      throw StateError('No adapter registered for kind: $kind');
    }
    return adapter;
  }
}
