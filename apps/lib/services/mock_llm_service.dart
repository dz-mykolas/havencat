import 'dart:async';
import 'dart:math';

/// A stand-in for a real LLM backend.
///
/// It emits a canned reply word-by-word with small delays to simulate token
/// streaming. Swap this out for a real provider (Gemini, OpenAI, Ollama, ...)
/// without touching the rest of the app, as long as the [reply] signature is
/// preserved.
class MockLlmService {
  MockLlmService({Random? random}) : _random = random ?? Random();

  final Random _random;

  static const List<String> _replies = <String>[
    "That's a great question. Here's how I'd think about it: "
        "start by breaking the problem into smaller pieces, then tackle each "
        "one in isolation. Once the parts work, composing them is usually the "
        "easy bit. Want me to go deeper on any step?",
    "Absolutely. At a high level there are a few moving parts to consider, "
        "and the right trade-off depends on your constraints. If you tell me "
        "more about your goals, I can tailor the recommendation more precisely.",
    "Sure! Imagine the system as a set of layers, each responsible for one "
        "concern. Keeping those boundaries clean makes the whole thing far "
        "easier to reason about and to change later on.",
    "Here are a few ideas to get you started, roughly ordered from simplest "
        "to most ambitious. Feel free to mix and match — none of these are "
        "mutually exclusive, and you can always iterate.",
  ];

  /// Streams the assistant reply for [prompt] one word at a time.
  Stream<String> reply(String prompt) async* {
    // A tiny "thinking" pause before the first token arrives.
    await Future<void>.delayed(const Duration(milliseconds: 450));

    final String response = _replies[_random.nextInt(_replies.length)];
    for (final String word in response.split(' ')) {
      await Future<void>.delayed(
        Duration(milliseconds: 28 + _random.nextInt(55)),
      );
      yield '$word ';
    }
  }
}
