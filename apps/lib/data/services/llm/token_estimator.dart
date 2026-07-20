import '../../../domain/models/message.dart';

/// Rough token estimate using the char/4 heuristic.
///
/// This is the standard fallback when a real tokenizer (tiktoken, etc.) isn't
/// available — Open WebUI ships the same approach for non-OpenAI models. It's
/// wrong by ~15-30% but consistently wrong, which is what matters for
/// threshold checks. The signature is stable so this can be swapped to a
/// real tokenizer later without touching call sites.
int estimateTokens(String text) => (text.length / 4).ceil();

/// Token estimate for a single message, including role/tool overhead.
int estimateMessageTokens(ChatMessage m) {
  int n = 4; // role + delimiters
  n += estimateTokens(m.text);
  // Image tokenization depends on provider, resolution, and detail level.
  // Reserve a conservative fixed amount so compaction does not treat image
  // turns as free when no provider tokenizer is available.
  n += m.attachments.length * 1024;
  for (final tc in m.toolCalls) {
    n += estimateTokens(tc.args) + 8;
  }
  return n;
}

/// Live estimate of tokens emitted for an assistant response so far.
int estimateGeneratedTokens(ChatMessage message) {
  int estimate = 4;
  estimate += estimateTokens(message.text);
  estimate += estimateTokens(message.reasoning);
  for (final ToolCall call in message.toolCalls) {
    estimate += estimateTokens(call.name);
    estimate += estimateTokens(call.args) + 8;
  }
  return estimate;
}

/// Token estimate for a list of messages.
int estimateMessagesTokens(List<ChatMessage> messages) =>
    messages.fold(0, (sum, m) => sum + estimateMessageTokens(m));
