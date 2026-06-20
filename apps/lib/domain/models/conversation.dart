import 'message.dart';

/// An in-memory conversation: an ordered list of [ChatMessage]s plus a title
/// shown in the conversation drawer.
///
/// The [providerAccountId] ties a conversation to the adapter that should
/// answer its messages. Null means "use the active provider".
class Conversation {
  Conversation({
    required this.id,
    this.title = 'New chat',
    List<ChatMessage>? messages,
    this.providerAccountId,
    this.createdAt,
  }) : messages = messages ?? <ChatMessage>[];

  final String id;
  String title;
  final List<ChatMessage> messages;

  /// Which configured provider account this conversation uses. Null = the
  /// currently active account (default for new chats).
  String? providerAccountId;

  DateTime? createdAt;

  bool get isEmpty => messages.isEmpty;
}
