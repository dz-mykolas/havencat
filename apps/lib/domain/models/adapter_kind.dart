/// Wire protocol an [LlmAdapter] implements. Authentication and UI grouping
/// are defined separately by each provider.
enum AdapterKind {
  /// ChatGPT's Codex Responses protocol, authenticated with ChatGPT OAuth.
  chatGptCodex,

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
