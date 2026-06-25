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

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'args': args};

  factory ToolCall.fromJson(Map<String, dynamic> json) => ToolCall(
    id: json['id'] as String,
    name: json['name'] as String,
    args: json['args'] as String,
  );
}

/// A single message in a conversation.
///
/// Plain mutable class (no freezed/codegen). The assistant message's [text]
/// grows token-by-token while [isStreaming] is true; the repository/viewmodel
/// mutate it in place and notify listeners.
///
/// Messages form a tree via [parentId] / [childrenIds]. The "active thread"
/// is the path from the conversation's [Conversation.currentLeafId] back to
/// the root. Editing/regenerating creates siblings rather than overwriting,
/// so prior branches are preserved. For a linear (non-branched) conversation
/// the tree degenerates to a linked list and activePath equals messages.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    this.text = '',
    this.isStreaming = false,
    this.createdAt,
    this.toolCalls = const <ToolCall>[],
    this.toolCallId,
    this.parentId,
    List<String>? children,
    this.originalContent,
  }) : childrenIds = children ?? <String>[];

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

  /// Id of the message this one replies to. Null for the conversation root.
  /// Siblings (alternate versions of the same logical turn) share a parentId.
  String? parentId;

  /// Ids of messages that reply to this one. Empty for a leaf.
  final List<String> childrenIds;

  /// Snapshot of [text] before an in-place edit, so the edit can be reverted
  /// without spawning a new branch. Null when the message was never edited
  /// in place. Only set on the first in-place edit; subsequent edits keep the
  /// original snapshot.
  String? originalContent;

  /// True when the stream that produced this message failed. The message is
  /// kept in the tree as a sibling (so the user can inspect it) but the active
  /// branch rolls back to the previous leaf. Used to show a failed indicator
  /// in the sibling counter.
  bool hasError = false;

  bool get isLeaf => childrenIds.isEmpty;

  /// Which child is the currently-selected branch. Used by
  /// [Conversation.selectSibling] to remember the chosen fork at each level
  /// when walking down to a leaf, instead of always picking the newest child.
  /// Null when there are no children or no selection has been made yet.
  String? activeChildId;

  /// True when [text] was changed in place (not via a new sibling branch).
  bool get isEdited => originalContent != null;

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;
  bool get isTool => role == MessageRole.tool;

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role.name,
    'text': text,
    'isStreaming': isStreaming,
    'createdAt': createdAt?.toIso8601String(),
    'toolCalls': toolCalls.map((tc) => tc.toJson()).toList(),
    'toolCallId': toolCallId,
    'parentId': parentId,
    'childrenIds': childrenIds,
    'originalContent': originalContent,
    'hasError': hasError,
    'activeChildId': activeChildId,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) =>
      ChatMessage(
          id: json['id'] as String,
          role: MessageRole.values.byName(json['role'] as String),
          text: json['text'] as String? ?? '',
          isStreaming: json['isStreaming'] as bool? ?? false,
          createdAt: json['createdAt'] != null
              ? DateTime.parse(json['createdAt'] as String)
              : null,
          toolCalls:
              (json['toolCalls'] as List<dynamic>?)
                  ?.map((e) => ToolCall.fromJson(e as Map<String, dynamic>))
                  .toList() ??
              const <ToolCall>[],
          toolCallId: json['toolCallId'] as String?,
          parentId: json['parentId'] as String?,
          children: (json['childrenIds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList(),
          originalContent: json['originalContent'] as String?,
        )
        ..hasError = json['hasError'] as bool? ?? false
        ..activeChildId = json['activeChildId'] as String?;
}
