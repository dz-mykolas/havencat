import 'dart:convert';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:http/http.dart' as http;

import 'platform_io.dart'
    if (dart.library.html) 'platform_web.dart'
    as platform;

import '../../../domain/models/conversation.dart';
import '../../../domain/models/message.dart';
import '../../../src/rust/api/conversations.dart' as rust;
import '../../../src/rust/conversations/db.dart' as rust_types;

/// Persists conversations to SQLite (via Rust on native, via HTTP on web).
///
/// Native: calls Rust directly through FRB FFI. The Rust side owns the SQLite
/// database file and handles schema migrations, upsert, delete, and load.
///
/// Web: calls the local server's `/api/conversations/*` JSON routes, which
/// in turn call the same Rust functions server-side.
abstract class ConversationStore {
  Future<List<Conversation>> load();
  Future<void> upsert(Conversation conversation);
  Future<void> delete(String id);
}

/// Rust-backed store for native (mobile/desktop). Calls the FRB-generated
/// bindings directly.
class RustConversationStore implements ConversationStore {
  @override
  Future<List<Conversation>> load() async {
    final List<rust_types.StoredConversation> stored = await rust
        .loadConversations();
    return stored.map(_toDomain).toList();
  }

  @override
  Future<void> upsert(Conversation conversation) async {
    await rust.upsertConversation(conv: _toStored(conversation));
  }

  @override
  Future<void> delete(String id) async {
    await rust.deleteConversation(id: id);
  }

  static Conversation _toDomain(rust_types.StoredConversation s) {
    final List<ChatMessage> messages = s.messages
        .map(_messageToDomain)
        .toList();
    final conv = Conversation(
      id: s.id,
      title: s.title,
      messages: messages,
      providerAccountId: s.providerAccount,
      createdAt: DateTime.tryParse(s.createdAt),
    )..currentLeafId = s.currentLeafId;
    return conv;
  }

  static ChatMessage _messageToDomain(rust_types.StoredMessage m) {
    final List<ToolCall> toolCalls = m.toolCallsJson != null
        ? (jsonDecode(m.toolCallsJson!) as List<dynamic>)
              .map((e) => ToolCall.fromJson(e as Map<String, dynamic>))
              .toList()
        : const <ToolCall>[];
    final List<String> childrenIds = m.childrenIds.isNotEmpty
        ? (jsonDecode(m.childrenIds) as List<dynamic>)
              .map((e) => e as String)
              .toList()
        : const <String>[];
    return ChatMessage(
        id: m.id,
        role: MessageRole.values.byName(m.role),
        text: m.text,
        createdAt: DateTime.tryParse(m.createdAt),
        toolCalls: toolCalls,
        toolCallId: m.toolCallId,
        parentId: m.parentId,
        children: childrenIds,
        originalContent: m.originalContent,
      )
      ..hasError = m.hasError
      ..activeChildId = m.activeChildId
      ..cleared = m.cleared
      ..clearedSummary = m.clearedSummary
      ..refetchArgs = m.refetchArgs != null
          ? jsonDecode(m.refetchArgs!) as Map<String, Object?>
          : null
      ..isCompactionSummary = m.isCompactionSummary
      ..promptTokens = _platformInt64ToInt(m.promptTokens)
      ..completionTokens = _platformInt64ToInt(m.completionTokens)
      ..totalTokens = _platformInt64ToInt(m.totalTokens);
  }

  static int? _platformInt64ToInt(PlatformInt64? v) {
    if (v == null) return null;
    // PlatformInt64 is int on native, BigInt on web. Cast through Object to
    // satisfy both type-checkers.
    final Object o = v;
    if (o is int) return o;
    return (o as BigInt).toInt();
  }

  static PlatformInt64? _intToPlatformInt64(int? v) {
    if (v == null) return null;
    return (platform.isWeb ? BigInt.from(v) : v) as PlatformInt64;
  }

  static rust_types.StoredConversation _toStored(Conversation c) {
    return rust_types.StoredConversation(
      id: c.id,
      title: c.title,
      providerAccount: c.providerAccountId,
      createdAt:
          c.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
      currentLeafId: c.currentLeafId,
      updatedAt: (platform.isWeb ? BigInt.zero : 0) as PlatformInt64,
      messages: c.messages.map((m) => _messageToStored(m, c.id)).toList(),
    );
  }

  static rust_types.StoredMessage _messageToStored(
    ChatMessage m,
    String conversationId,
  ) {
    return rust_types.StoredMessage(
      id: m.id,
      conversationId: conversationId,
      role: m.role.name,
      text: m.text,
      parentId: m.parentId,
      childrenIds: jsonEncode(m.childrenIds),
      originalContent: m.originalContent,
      hasError: m.hasError,
      activeChildId: m.activeChildId,
      toolCallId: m.toolCallId,
      toolCallsJson: m.toolCalls.isNotEmpty
          ? jsonEncode(m.toolCalls.map((tc) => tc.toJson()).toList())
          : null,
      createdAt:
          m.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
      cleared: m.cleared,
      clearedSummary: m.clearedSummary,
      refetchArgs: m.refetchArgs != null ? jsonEncode(m.refetchArgs) : null,
      isCompactionSummary: m.isCompactionSummary,
      promptTokens: _intToPlatformInt64(m.promptTokens),
      completionTokens: _intToPlatformInt64(m.completionTokens),
      totalTokens: _intToPlatformInt64(m.totalTokens),
    );
  }
}

/// HTTP-backed store for web. Calls the local server's `/api/conversations/*`
/// routes, which proxy to the same Rust SQLite layer.
class HttpConversationStore implements ConversationStore {
  HttpConversationStore({String? baseUrl, http.Client? client})
    : _baseUrl = (baseUrl ?? '').replaceAll(RegExp(r'/+$'), ''),
      _client = client ?? http.Client();

  final String _baseUrl;
  final http.Client _client;

  @override
  Future<List<Conversation>> load() async {
    final resp = await _client.get(
      Uri.parse('$_baseUrl/api/conversations'),
      headers: _acceptJson,
    );
    if (resp.statusCode != 200) {
      throw ConversationStoreException(
        'load failed: ${resp.statusCode} ${resp.body}',
      );
    }
    final List<dynamic> json = jsonDecode(resp.body) as List<dynamic>;
    return json
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<void> upsert(Conversation conversation) async {
    final resp = await _client.put(
      Uri.parse('$_baseUrl/api/conversations/${conversation.id}'),
      headers: {'content-type': 'application/json', ..._acceptJson},
      body: jsonEncode(conversation.toJson()),
    );
    if (resp.statusCode != 204) {
      throw ConversationStoreException(
        'upsert failed: ${resp.statusCode} ${resp.body}',
      );
    }
  }

  @override
  Future<void> delete(String id) async {
    final resp = await _client.delete(
      Uri.parse('$_baseUrl/api/conversations/$id'),
      headers: _acceptJson,
    );
    if (resp.statusCode != 204) {
      throw ConversationStoreException(
        'delete failed: ${resp.statusCode} ${resp.body}',
      );
    }
  }

  static const Map<String, String> _acceptJson = {'accept': 'application/json'};
}

/// Thrown by [HttpConversationStore] when a server request fails.
class ConversationStoreException implements Exception {
  ConversationStoreException(this.message);
  final String message;

  @override
  String toString() => 'ConversationStoreException: $message';
}

/// No-op store for tests — keeps everything in memory, never persists.
class InMemoryConversationStore implements ConversationStore {
  @override
  Future<List<Conversation>> load() async => const <Conversation>[];

  @override
  Future<void> upsert(Conversation conversation) async {}

  @override
  Future<void> delete(String id) async {}
}

/// Picks the right store for the current platform.
ConversationStore createConversationStore({String? httpBaseUrl}) {
  if (platform.isWeb) {
    return HttpConversationStore(baseUrl: httpBaseUrl);
  }
  return RustConversationStore();
}
