import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/conversation.dart';
import '../models/message.dart';
import '../services/mock_llm_service.dart';

/// Owns the list of conversations and the currently active one, and drives the
/// (mock) streaming reply flow. UI listens via [ListenableBuilder].
class ChatController extends ChangeNotifier {
  ChatController({MockLlmService? service})
    : _service = service ?? MockLlmService() {
    _conversations.add(Conversation(id: _newId()));
    _activeId = _conversations.first.id;
  }

  final MockLlmService _service;
  final List<Conversation> _conversations = <Conversation>[];

  late String _activeId;
  bool _isGenerating = false;
  StreamSubscription<String>? _replySub;
  int _counter = 0;

  List<Conversation> get conversations => List.unmodifiable(_conversations);
  bool get isGenerating => _isGenerating;

  Conversation get active =>
      _conversations.firstWhere((Conversation c) => c.id == _activeId);

  String get activeId => _activeId;

  String _newId() =>
      'id_${DateTime.now().microsecondsSinceEpoch}_${_counter++}';

  /// Creates a fresh conversation and makes it active.
  void newConversation() {
    if (active.isEmpty) {
      // Avoid stacking up empty "New chat" entries.
      return;
    }
    final Conversation conversation = Conversation(id: _newId());
    _conversations.insert(0, conversation);
    _activeId = conversation.id;
    notifyListeners();
  }

  /// Switches the active conversation shown in the chat view.
  void selectConversation(String id) {
    if (id == _activeId) return;
    _activeId = id;
    notifyListeners();
  }

  /// Appends the user's [text], then streams a mock assistant reply.
  Future<void> sendMessage(String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty || _isGenerating) return;

    final Conversation conversation = active;
    final bool wasEmpty = conversation.isEmpty;

    conversation.messages.add(
      ChatMessage(id: _newId(), role: MessageRole.user, text: trimmed),
    );

    if (wasEmpty) {
      conversation.title = _titleFrom(trimmed);
    }

    final ChatMessage assistant = ChatMessage(
      id: _newId(),
      role: MessageRole.assistant,
      isStreaming: true,
    );
    conversation.messages.add(assistant);

    _isGenerating = true;
    notifyListeners();

    final Completer<void> done = Completer<void>();
    _replySub = _service
        .reply(trimmed)
        .listen(
          (String chunk) {
            assistant.text += chunk;
            notifyListeners();
          },
          onDone: () {
            assistant.text = assistant.text.trimRight();
            assistant.isStreaming = false;
            _isGenerating = false;
            notifyListeners();
            if (!done.isCompleted) done.complete();
          },
          onError: (Object error) {
            assistant.text = 'Something went wrong. Please try again.';
            assistant.isStreaming = false;
            _isGenerating = false;
            notifyListeners();
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );

    return done.future;
  }

  static String _titleFrom(String text) {
    final String oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= 32) return oneLine;
    return '${oneLine.substring(0, 32).trimRight()}…';
  }

  @override
  void dispose() {
    _replySub?.cancel();
    super.dispose();
  }
}
