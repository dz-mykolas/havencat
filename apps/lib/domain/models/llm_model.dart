import 'content_modality.dart';

/// Provider-neutral capabilities advertised for a model.
class ModelCapabilities {
  const ModelCapabilities({
    this.input = const <ContentModality>{ContentModality.text},
    this.output = const <ContentModality>{ContentModality.text},
    this.reasoning = false,
    this.toolCalling = false,
    this.attachments = false,
  });

  factory ModelCapabilities.fromJson(Map<String, Object?> json) {
    Set<ContentModality> modalities(String key) {
      return (json[key] as List)
          .map(
            (Object? value) => ContentModality.values.byName(value! as String),
          )
          .toSet();
    }

    return ModelCapabilities(
      input: modalities('input'),
      output: modalities('output'),
      reasoning: json['reasoning']! as bool,
      toolCalling: json['toolCalling']! as bool,
      attachments: json['attachments']! as bool,
    );
  }

  final Set<ContentModality> input;
  final Set<ContentModality> output;
  final bool reasoning;
  final bool toolCalling;
  final bool attachments;

  bool accepts(ContentModality modality) => input.contains(modality);
  bool produces(ContentModality modality) => output.contains(modality);

  Map<String, Object?> toJson() => <String, Object?>{
    'input': input.map((ContentModality value) => value.name).toList(),
    'output': output.map((ContentModality value) => value.name).toList(),
    'reasoning': reasoning,
    'toolCalling': toolCalling,
    'attachments': attachments,
  };
}

/// A model a provider exposes, as returned by its "list models" endpoint.
///
/// Models are fetched dynamically per account (never hardcoded); [id] is what
/// gets sent on the wire, [displayName] is an optional human label.
class LlmModel {
  const LlmModel({
    required this.id,
    this.displayName,
    this.hidden = false,
    this.contextWindow,
    this.capabilities,
  });

  /// Wire id, e.g. 'gpt-4o', 'claude-3-5-sonnet-latest', 'qwen-max'.
  final String id;

  /// Optional friendlier label; falls back to [id] via [label].
  final String? displayName;

  /// Whether the provider marks this model as hidden/internal (e.g. ChatGPT's
  /// `codex-auto-review`). Hidden models are filtered out of the picker unless
  /// the global "show hidden models" setting is on.
  final bool hidden;

  /// Approximate context window in tokens, if known. Populated by
  /// cross-referencing the models.dev catalog.
  /// Null when unknown — callers fall back to a conservative default.
  final int? contextWindow;

  /// Null means capability metadata was unavailable; it does not mean the
  /// model is text-only.
  final ModelCapabilities? capabilities;

  /// What to show in the UI.
  String get label =>
      (displayName != null && displayName!.isNotEmpty) ? displayName! : id;

  @override
  bool operator ==(Object other) =>
      other is LlmModel &&
      other.id == id &&
      other.displayName == displayName &&
      other.hidden == hidden &&
      other.contextWindow == contextWindow &&
      _capabilitiesEqual(other.capabilities, capabilities);

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    hidden,
    contextWindow,
    capabilities == null ? null : _capabilitiesHash(capabilities!),
  );

  static int _capabilitiesHash(ModelCapabilities value) {
    final List<String> input =
        value.input.map((ContentModality modality) => modality.name).toList()
          ..sort();
    final List<String> output =
        value.output.map((ContentModality modality) => modality.name).toList()
          ..sort();
    return Object.hashAll(<Object?>[
      ...input,
      ...output,
      value.reasoning,
      value.toolCalling,
      value.attachments,
    ]);
  }

  static bool _capabilitiesEqual(ModelCapabilities? a, ModelCapabilities? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.input.length == b.input.length &&
        a.input.containsAll(b.input) &&
        a.output.length == b.output.length &&
        a.output.containsAll(b.output) &&
        a.reasoning == b.reasoning &&
        a.toolCalling == b.toolCalling &&
        a.attachments == b.attachments;
  }
}
