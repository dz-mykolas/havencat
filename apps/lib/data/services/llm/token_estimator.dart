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
  for (final tc in m.toolCalls) {
    n += estimateTokens(tc.args) + 8;
  }
  return n;
}

/// Token estimate for a list of messages.
int estimateMessagesTokens(List<ChatMessage> messages) =>
    messages.fold(0, (sum, m) => sum + estimateMessageTokens(m));
