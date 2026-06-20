/// A model a provider exposes, as returned by its "list models" endpoint.
///
/// Models are fetched dynamically per account (never hardcoded); [id] is what
/// gets sent on the wire, [displayName] is an optional human label.
class LlmModel {
  const LlmModel({required this.id, this.displayName, this.hidden = false});

  /// Wire id, e.g. 'gpt-4o', 'claude-3-5-sonnet-latest', 'qwen-max'.
  final String id;

  /// Optional friendlier label; falls back to [id] via [label].
  final String? displayName;

  /// Whether the provider marks this model as hidden/internal (e.g. ChatGPT's
  /// `codex-auto-review`). Hidden models are filtered out of the picker unless
  /// the global "show hidden models" setting is on.
  final bool hidden;

  /// What to show in the UI.
  String get label => (displayName != null && displayName!.isNotEmpty)
      ? displayName!
      : id;

  @override
  bool operator ==(Object other) =>
      other is LlmModel &&
      other.id == id &&
      other.displayName == displayName &&
      other.hidden == hidden;

  @override
  int get hashCode => Object.hash(id, displayName, hidden);
}
