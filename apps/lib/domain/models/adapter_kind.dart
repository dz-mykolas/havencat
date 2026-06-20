/// High-level family an [LlmAdapter] belongs to. Drives UI grouping (the
/// "Subscription logins" section vs the "API keys" section) and which factory
/// the registry uses to build the adapter.
enum AdapterKind {
  /// Uses a user's existing subscription via OAuth (e.g. ChatGPT, Poe).
  subscription,

  /// Generic OpenAI-compatible `/v1/chat/completions` endpoint with an API
  /// key. Covers OpenAI API, Qwen, OpenRouter, Groq, Together, DeepSeek,
  /// Ollama, LM Studio, vLLM, and any custom OpenAI-compatible endpoint.
  openaiCompatible,

  /// Anthropic Messages API.
  anthropic,

  /// Gemini native API.
  geminiNative,

  /// Runs a model on-device (future, Rust-backed via flutter_rust_bridge).
  onDevice,

  /// Local mock for development. No network.
  mock,
}
