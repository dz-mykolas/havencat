/// System prompts sent to the model alongside the conversation.
///
/// Kept here (not in the adapter layer) so the repository — which owns the
/// "what should the model do" policy — is the single source of truth, and the
/// adapters stay dumb transport for whatever instructions they're handed.
///
/// This prompt is strictly about output formatting for the chat's Markdown
/// renderer. It deliberately does NOT set a persona or assistant behaviour —
/// that is the user's job via custom agent instructions, which take precedence.
class SystemPrompts {
  SystemPrompts._();

  /// Markdown formatting guidance prepended to every conversation.
  ///
  /// Tells the model how to format its output so the chat's Markdown renderer
  /// (copy buttons on code blocks, tap-to-copy inline code, link handling,
  /// LaTeX, tables, etc.) works well. Rather than detecting "things that look
  /// like codes/keys" with regex on the rendered text, the model is asked to
  /// wrap anything copy-worthy in inline code so the renderer's built-in
  /// tap-to-copy chip picks it up automatically.
  ///
  /// Keep this prompt formatting-only. Persona/behaviour instructions belong
  /// in user-configurable agent instructions, not here.
  static const String base = '''
The chat renders your Markdown output with these features — use them deliberately:

- **Code blocks** for multi-line code — use a fenced block with a language tag:
  ```dart
  print('hi');
  ```
  Each code block gets its own copy button, so keep each block self-contained and copy-ready.

- **Inline code** (single backticks) for anything short that the user will likely want to copy verbatim: redeem codes, gift card codes, promo codes, license keys, API keys, tokens, OTPs, tracking numbers, order IDs, file paths, commands, identifiers. Example:
  Your redeem code is `ABCD-1234-EFGH` — enter it at checkout.
  Putting a value in inline code makes it a one-tap copy chip in the UI.

- **Bold** (`**text**`) only for real emphasis, not headings.

- **Headings** (`#`, `##`, `###`) to structure longer answers; don't overuse them for short replies.

- **Tables** for structured comparisons.

- **Links** as `[text](url)` — they open in the browser when tapped.

- **LaTeX** for math: inline `\\( ... \\)` and block `\\[ ... \\]`.

- **Lists** (`-` or `1.`) for steps and enumerations.

Prefer inline code over quotes for values the user should copy. Don't wrap whole sentences in code, only the copy-worthy token itself.
''';
}
