/// Whether a [ChatMessage] was authored by the user or the assistant.
enum MessageRole { user, assistant }

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
  });

  final String id;
  final MessageRole role;

  /// The (possibly partial, while streaming) message content.
  String text;

  /// True while the assistant is still appending tokens to [text].
  bool isStreaming;

  /// When the message was created. Null only for legacy/mock messages.
  DateTime? createdAt;

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;
}
