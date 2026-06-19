import 'message.dart';

/// An in-memory conversation: an ordered list of [ChatMessage]s plus a title
/// shown in the conversation drawer.
class Conversation {
  Conversation({
    required this.id,
    this.title = 'New chat',
    List<ChatMessage>? messages,
  }) : messages = messages ?? <ChatMessage>[];

  final String id;
  String title;
  final List<ChatMessage> messages;

  bool get isEmpty => messages.isEmpty;
}
