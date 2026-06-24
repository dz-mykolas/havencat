/// Whether a [ChatMessage] was authored by the user, the assistant, or
/// synthesized as a tool result.
enum MessageRole { user, assistant, tool }

/// A tool call the assistant emitted (OpenAI `tool_calls` shape). Attached to
/// the assistant message that produced it so the conversation history can be
/// replayed to the provider with the calls inline.
class ToolCall {
  ToolCall({required this.id, required this.name, required this.args});

  /// Provider-assigned id of the call (used to correlate the tool result).
  final String id;

  /// Function name, e.g. 'web_search'.
  final String name;

  /// Raw JSON arguments string as the model emitted it.
  String args;
}

/// A single message in a conversation.
///
/// Plain mutable class (no freezed/codegen). The assistant message's [text]
/// grows token-by-token while [isStreaming] is true; the repository/viewmodel
/// mutate it in place and notify listeners.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    this.text = '',
    this.isStreaming = false,
    this.createdAt,
    this.toolCalls = const <ToolCall>[],
    this.toolCallId,
  });

  final String id;
  final MessageRole role;

  /// The (possibly partial, while streaming) message content.
  String text;

  /// True while the assistant is still appending tokens to [text].
  bool isStreaming;

  /// When the message was created. Null only for legacy/mock messages.
  DateTime? createdAt;

  /// Tool calls the assistant emitted on this turn (OpenAI `tool_calls`).
  /// Empty for user/tool messages. Accumulated while streaming.
  List<ToolCall> toolCalls;

  /// For [MessageRole.tool] messages: the id of the call this is a result for.
  final String? toolCallId;

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;
  bool get isTool => role == MessageRole.tool;
}
