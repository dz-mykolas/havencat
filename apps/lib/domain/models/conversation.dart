import 'message.dart';

/// An in-memory conversation: an ordered list of [ChatMessage]s plus a title
/// shown in the conversation drawer.
///
/// The [providerAccountId] ties a conversation to the adapter that should
/// answer its messages. Null means "use the active provider".
///
/// Messages form a tree (see [ChatMessage.parentId]). [currentLeafId] points
/// at the tip of the currently-visible branch; [activePath] walks it back to
/// the root. For conversations created before branching existed, the tree is a
/// linear chain and [activePath] equals [messages].
class Conversation {
  Conversation({
    required this.id,
    this.title = 'New chat',
    List<ChatMessage>? messages,
    this.providerAccountId,
    this.createdAt,
  }) : messages = messages ?? <ChatMessage>[] {
    _reindex();
  }

  final String id;
  String title;
  final List<ChatMessage> messages;

  /// Which configured provider account this conversation uses. Null = the
  /// currently active account (default for new chats).
  String? providerAccountId;

  DateTime? createdAt;

  /// Id of the leaf of the active branch. Null only when the conversation is
  /// empty. Updated by [add] and by branch-switching (phase 2).
  String? currentLeafId;

  /// Prompt-token count reported by the provider for the most recent reply.
  /// Used to calibrate the char/4 estimator. Null when the provider doesn't
  /// report usage (e.g. Ollama) or before the first reply.
  int? lastPromptTokens;

  /// Completion-token count reported by the provider for the most recent
  /// reply. Null when the provider doesn't report usage or before the first
  /// reply.
  int? lastCompletionTokens;

  /// Total-token count (input + output) reported by the provider for the
  /// most recent reply. Null when the provider doesn't report usage or
  /// before the first reply.
  int? lastTotalTokens;

  /// The char/4 estimate of the messages sent in the most recent request.
  /// Paired with [lastPromptTokens] to compute a calibration ratio for the
  /// estimator. Null before the first reply.
  int? lastEstimatedTokens;

  final Map<String, ChatMessage> _byId = <String, ChatMessage>{};

  /// Looks up a message by id in O(1). Returns null for unknown ids.
  ChatMessage? byId(String id) => _byId[id];

  /// Messages on the active branch, root → leaf, with orphan tool results
  /// (whose [ChatMessage.toolCallId] doesn't match any call on this path)
  /// filtered out. This is what gets sent to the LLM and rendered by the UI.
  List<ChatMessage> get activePath {
    final String? leaf = currentLeafId;
    if (leaf == null) return const <ChatMessage>[];
    final List<ChatMessage> path = <ChatMessage>[];
    String? id = leaf;
    while (id != null) {
      final ChatMessage? m = _byId[id];
      if (m == null) break;
      path.insert(0, m);
      id = m.parentId;
    }
    final Set<String> callIds = path
        .expand((ChatMessage m) => m.toolCalls.map((ToolCall c) => c.id))
        .toSet();
    return path.where((ChatMessage m) {
      if (m.role != MessageRole.tool) return true;
      return m.toolCallId != null && callIds.contains(m.toolCallId);
    }).toList();
  }

  /// Sibling message ids of [id] (including [id] itself). Empty for a
  /// non-root message with no parent. For root messages (parentId is null),
  /// all other root messages are siblings.
  List<String> siblingsOf(String id) {
    final ChatMessage? m = _byId[id];
    if (m == null) return const <String>[];
    if (m.parentId == null) {
      // Root messages are siblings of each other.
      return messages
          .where((msg) => msg.parentId == null)
          .map((msg) => msg.id)
          .toList();
    }
    final ChatMessage? parent = _byId[m.parentId!];
    return parent?.childrenIds ?? const <String>[];
  }

  /// Appends [m] as a child of the current leaf (or [parentId] if given),
  /// updates the id index, and advances [currentLeafId] to [m]. Use
  /// [parentId] to create a sibling when branching. Pass [parentId] as null
  /// explicitly (via [parentId]) to create a root-level message — to
  /// distinguish "not provided" from "explicitly null", [parentId] is a
  /// nullable wrapper.
  void add(ChatMessage m, {String? parentId, bool isRoot = false}) {
    final String? p = isRoot ? null : (parentId ?? currentLeafId);
    m.parentId = p;
    if (p != null) {
      final ChatMessage? parent = _byId[p];
      if (parent != null && !parent.childrenIds.contains(m.id)) {
        parent.childrenIds.add(m.id);
        parent.activeChildId = m.id;
      }
    }
    messages.add(m);
    _byId[m.id] = m;
    currentLeafId = m.id;
  }

  /// Rebuilds the id index and derives [currentLeafId] when unset. Called on
  /// construction and after any direct mutation of [messages].
  void _reindex() {
    _byId.clear();
    for (final ChatMessage m in messages) {
      _byId[m.id] = m;
    }
    if (currentLeafId == null || _byId[currentLeafId] == null) {
      currentLeafId = messages.isEmpty ? null : messages.last.id;
    }
  }

  /// Counts all descendants of [id] (children + their children, recursively).
  /// Used by the UI to show a cache-cost hint when editing a message that has
  /// downstream content.
  int descendantCount(String id) {
    final ChatMessage? m = _byId[id];
    if (m == null) return 0;
    int count = 0;
    for (final String childId in m.childrenIds) {
      count += 1 + descendantCount(childId);
    }
    return count;
  }

  bool get isEmpty => messages.isEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'messages': messages.map((m) => m.toJson()).toList(),
    'providerAccountId': providerAccountId,
    'createdAt': createdAt?.toIso8601String(),
    'currentLeafId': currentLeafId,
    'lastPromptTokens': lastPromptTokens,
    'lastCompletionTokens': lastCompletionTokens,
    'lastTotalTokens': lastTotalTokens,
    'lastEstimatedTokens': lastEstimatedTokens,
  };

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final conv =
        Conversation(
            id: json['id'] as String,
            title: json['title'] as String? ?? 'New chat',
            messages:
                (json['messages'] as List<dynamic>?)
                    ?.map(
                      (e) => ChatMessage.fromJson(e as Map<String, dynamic>),
                    )
                    .toList() ??
                <ChatMessage>[],
            providerAccountId: json['providerAccountId'] as String?,
            createdAt: json['createdAt'] != null
                ? DateTime.parse(json['createdAt'] as String)
                : null,
          )
          ..currentLeafId = json['currentLeafId'] as String?
          ..lastPromptTokens = json['lastPromptTokens'] as int?
          ..lastCompletionTokens = json['lastCompletionTokens'] as int?
          ..lastTotalTokens = json['lastTotalTokens'] as int?
          ..lastEstimatedTokens = json['lastEstimatedTokens'] as int?;
    return conv;
  }
}
