/// Whether a [ChatMessage] was authored by the user or the assistant.
enum MessageRole { user, assistant }

/// A single message in a conversation.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    this.text = '',
    this.isStreaming = false,
  });

  final String id;
  final MessageRole role;

  /// The (possibly partial, while streaming) message content.
  String text;

  /// True while the assistant is still appending tokens to [text].
  bool isStreaming;

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;
}
