/// Redacts common secret formats from text before it reaches the summarizer
/// LLM or gets persisted in a compaction summary.
///
/// Patterns are intentionally conservative — they target high-confidence
/// secret shapes (prefixed tokens, well-known key formats) to avoid
/// clobbering non-secret content. When in doubt, the redactor replaces with
/// `[REDACTED]` rather than risking a leak.
///
/// This is defense-in-depth: it runs before the LLM sees the text, AND the
/// summary prompt instructs the model not to include any secrets that slip
/// through. Neither layer alone is sufficient.
library;

/// A single redaction rule: a regex and the replacement string.
class _RedactionRule {
  const _RedactionRule(this.pattern, this.replacement);

  final RegExp pattern;
  final String replacement;
}

/// Compiled redaction rules, ordered most-specific first.
final List<_RedactionRule> _rules = <_RedactionRule>[
  // GitHub personal access tokens (classic + fine-grained): ghp_, gho_,
  // ghu_, ghs_, ghr_ followed by 36+ base62 chars.
  _RedactionRule(
    RegExp(r'''\bgh[pousr]_[A-Za-z0-9]{36,}\b'''),
    '[REDACTED:github_token]',
  ),

  // OpenAI API keys: sk-proj-, sk- followed by 20+ alphanumeric chars.
  _RedactionRule(
    RegExp(r'''\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b'''),
    '[REDACTED:openai_key]',
  ),

  // Anthropic API keys: sk-ant- followed by 40+ chars.
  _RedactionRule(
    RegExp(r'''\bsk-ant-[A-Za-z0-9_-]{40,}\b'''),
    '[REDACTED:anthropic_key]',
  ),

  // AWS access key ids: AKIA followed by 16 uppercase alphanumerics.
  _RedactionRule(RegExp(r'''\bAKIA[0-9A-Z]{16}\b'''), '[REDACTED:aws_key_id]'),

  // AWS secret access keys: 40-char base64 after a known prefix label.
  _RedactionRule(
    RegExp(
      r'''(?:aws_secret_access_key|aws_secret)\s*[:=]\s*["']?([A-Za-z0-9/+=]{40})["']?''',
      caseSensitive: false,
    ),
    '[REDACTED:aws_secret]',
  ),

  // Generic Bearer tokens in Authorization headers.
  _RedactionRule(
    RegExp(r'''\bBearer\s+[A-Za-z0-9._\-/+=]{20,}\b''', caseSensitive: false),
    '[REDACTED:bearer_token]',
  ),

  // Generic api_key / apikey / api-key assignments with a value.
  _RedactionRule(
    RegExp(
      r'''(?:api[_-]?key)\s*[:=]\s*["']([A-Za-z0-9._\-/+=]{16,})["']''',
      caseSensitive: false,
    ),
    '[REDACTED:api_key]',
  ),

  // Generic password / passwd / pwd assignments with a value.
  _RedactionRule(
    RegExp(
      r'''(?:password|passwd|pwd)\s*[:=]\s*["']([^"']{4,})["']''',
      caseSensitive: false,
    ),
    '[REDACTED:password]',
  ),

  // Generic token / access_token / auth_token assignments with a value.
  _RedactionRule(
    RegExp(
      r'''(?:access[_-]?token|auth[_-]?token|token)\s*[:=]\s*["']([A-Za-z0-9._\-/+=]{16,})["']''',
      caseSensitive: false,
    ),
    '[REDACTED:token]',
  ),

  // Slack tokens: xoxb-, xoxp-, xoxa-, xoxr- followed by 10+ chars.
  _RedactionRule(
    RegExp(r'''\bxox[abpr]-[A-Za-z0-9-]{10,}\b'''),
    '[REDACTED:slack_token]',
  ),

  // Stripe keys: sk_live_, sk_test_, pk_live_, pk_test_.
  _RedactionRule(
    RegExp(r'''\b(?:sk|pk)_(?:live|test)_[A-Za-z0-9]{16,}\b'''),
    '[REDACTED:stripe_key]',
  ),

  // Google API keys: AIza followed by 35 base64 chars.
  _RedactionRule(
    RegExp(r'''\bAIza[0-9A-Za-z_-]{35}\b'''),
    '[REDACTED:google_api_key]',
  ),

  // Private key blocks (PEM): redact the entire body.
  _RedactionRule(
    RegExp(
      r'''-----BEGIN (?:RSA |EC |OPENSSH |PGP |)PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH |PGP |)PRIVATE KEY-----''',
    ),
    '[REDACTED:private_key_block]',
  ),
];

/// Redacts known secret patterns from [text], replacing each with a
/// descriptive `[REDACTED:*]` marker.
///
/// Returns the redacted text. The original is not mutated. When [enabled]
/// is false, returns [text] unchanged (the caller controls the toggle).
String redactSecrets(String text, {bool enabled = true}) {
  if (!enabled || text.isEmpty) return text;
  String result = text;
  for (final _RedactionRule rule in _rules) {
    result = result.replaceAll(rule.pattern, rule.replacement);
  }
  return result;
}
