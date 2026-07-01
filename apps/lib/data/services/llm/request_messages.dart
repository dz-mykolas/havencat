import 'dart:convert';

import 'package:logging/logging.dart';

import '../../../domain/models/message.dart';
import 'token_estimator.dart';

final Logger _log = Logger('context');

/// Result of splitting the active path into the compactable "old" section and
/// the verbatim "recent tail".
class _Split {
  const _Split(this.old, this.recent);
  final List<ChatMessage> old;
  final List<ChatMessage> recent;
}

/// Approximate token budget reserved for the recent tail (the verbatim
/// section), as a fraction of the context window. ~25% keeps the last few
/// exchanges fully intact while leaving room for the summary + the model's
/// reply. Clamped to [_recentTailMinTokens] / [_recentTailMaxTokens].
const double _recentTailFraction = 0.25;

/// Floor for the recent tail budget — below this and the model loses too
/// much recent context for short conversations.
const int _recentTailMinTokens = 8000;

/// Ceiling for the recent tail budget — above this and the summary has too
/// little room to be useful, even on very large context windows.
const int _recentTailMaxTokens = 40000;

/// Minimum number of messages kept in the recent tail regardless of token
/// budget, so very short messages don't cause an oversized old section.
const int _recentTailMinMessages = 6;

/// Builds the message list to send to the LLM, applying context-management
/// policies: tool-result clearing and (optionally) compaction.
///
/// The stored conversation tree is never modified — this returns a request-
/// time view. Tool results from the current turn ([currentTurnMessageIds])
/// are always kept verbatim; only older tool results are cleared.
///
/// [contextWindow] is the model's context window in tokens (null = unknown,
/// falls back to a conservative default). [compactor] is invoked when the
/// estimated token count exceeds ~70% of the context window. When null, no
/// compaction happens (only clearing).
///
/// [calibrationRatio] adjusts the char/4 estimate to match the provider's
/// reported token counts. Derived from `lastPromptTokens / lastEstimatedTokens`
/// on the conversation. Null = no calibration data yet (first turn or provider
/// doesn't report usage).
List<ChatMessage> buildRequestMessages({
  required List<ChatMessage> activePath,
  required int? contextWindow,
  required ContextCompactor? compactor,
  required Set<String> currentTurnMessageIds,
  double? calibrationRatio,
}) {
  if (activePath.isEmpty) return activePath;

  final split = _splitForCompaction(activePath, contextWindow);
  final clearedOld = _clearOldToolResults(
    split.old,
    activePath,
    currentTurnMessageIds,
  );

  // No compactor or no context window → just return cleared + recent.
  if (compactor == null || contextWindow == null) {
    return <ChatMessage>[...clearedOld, ...split.recent];
  }

  final threshold = (contextWindow * 0.7).floor();
  final estimated = _calibratedEstimate(
    clearedOld,
    split.recent,
    calibrationRatio,
  );
  if (estimated <= threshold) {
    return <ChatMessage>[...clearedOld, ...split.recent];
  }

  // Over budget — compact the old section into a summary.
  // This is async (LLM call); the caller awaits via the compactor.
  // For the synchronous path, we return the cleared view (fail-safe) and
  // let the async wrapper handle compaction.
  return <ChatMessage>[...clearedOld, ...split.recent];
}

/// Async variant that performs compaction via an LLM call when over budget.
/// Falls back to the cleared view on any error (fail safe).
///
/// [calibrationRatio] adjusts the char/4 estimate to match the provider's
/// reported token counts (see [buildRequestMessages]).
Future<List<ChatMessage>> buildRequestMessagesAsync({
  required List<ChatMessage> activePath,
  required int? contextWindow,
  required ContextCompactor? compactor,
  required Set<String> currentTurnMessageIds,
  double? calibrationRatio,
}) async {
  if (activePath.isEmpty) return activePath;

  final split = _splitForCompaction(activePath, contextWindow);

  final clearedOld = _clearOldToolResults(
    split.old,
    activePath,
    currentTurnMessageIds,
  );

  if (compactor == null || contextWindow == null) {
    _log.fine(
      'compaction skipped: compactor=${compactor == null ? "null" : "set"} '
      'contextWindow=$contextWindow',
    );
    return <ChatMessage>[...clearedOld, ...split.recent];
  }

  final threshold = (contextWindow * 0.7).floor();
  final oldTokens = estimateMessagesTokens(clearedOld);
  final recentTokens = estimateMessagesTokens(split.recent);
  final rawEstimate = oldTokens + recentTokens;
  final estimated = calibrationRatio != null
      ? (rawEstimate * calibrationRatio).round()
      : rawEstimate;

  if (estimated <= threshold) {
    _log.fine(
      'compaction not triggered: estimated=$estimated threshold=$threshold '
      '(old=$oldTokens recent=$recentTokens contextWindow=$contextWindow '
      'calibration=${calibrationRatio?.toStringAsFixed(2)})',
    );
    return <ChatMessage>[...clearedOld, ...split.recent];
  }

  _log.info(
    'compaction triggered: estimated=$estimated threshold=$threshold '
    '(old=$oldTokens recent=$recentTokens contextWindow=$contextWindow '
    'calibration=${calibrationRatio?.toStringAsFixed(2)} '
    'oldMsgs=${clearedOld.length} recentMsgs=${split.recent.length})',
  );

  try {
    final result = await compactor.compact(clearedOld, split.recent);
    _log.info(
      'compaction done: result=${result.length} messages '
      '(was ${clearedOld.length + split.recent.length})',
    );
    return result;
  } catch (e, stack) {
    _log.warning(
      'compaction failed, falling back to cleared history: $e',
      e,
      stack,
    );
    return <ChatMessage>[...clearedOld, ...split.recent];
  }
}

/// Computes the calibrated token estimate for [old] + [recent]. When
/// [calibrationRatio] is null (no provider usage data yet), returns the raw
/// char/4 estimate.
int _calibratedEstimate(
  List<ChatMessage> old,
  List<ChatMessage> recent,
  double? calibrationRatio,
) {
  final raw = estimateMessagesTokens(old) + estimateMessagesTokens(recent);
  if (calibrationRatio == null) return raw;
  return (raw * calibrationRatio).round();
}

/// Splits the active path into [old, recent] where [recent] is at least
/// [_recentTailMinMessages] messages and at most a dynamic token budget
/// derived from [contextWindow] (25% of the window, clamped to
/// [_recentTailMinTokens]–[_recentTailMaxTokens]). Never splits an assistant
/// tool-call from its result — if the split point lands between them, the
/// assistant message moves to recent.
_Split _splitForCompaction(List<ChatMessage> path, int? contextWindow) {
  final int tailBudget = contextWindow == null
      ? _recentTailMinTokens
      : (contextWindow * _recentTailFraction).floor().clamp(
          _recentTailMinTokens,
          _recentTailMaxTokens,
        );
  if (path.length <= _recentTailMinMessages) {
    return _Split(const <ChatMessage>[], path);
  }

  // Walk backwards from the leaf, accumulating the recent tail.
  int tokens = 0;
  int splitIdx = path.length;
  for (int i = path.length - 1; i >= 0; i--) {
    final m = path[i];
    final t = estimateMessageTokens(m);
    if (tokens + t > tailBudget &&
        (path.length - i) >= _recentTailMinMessages) {
      splitIdx = i + 1;
      break;
    }
    tokens += t;
    splitIdx = i;
  }

  // Ensure we don't split an assistant tool-call from its results. If the
  // last "old" message is an assistant with tool calls, move it (and the
  // boundary) to recent.
  if (splitIdx > 0 && splitIdx < path.length) {
    final lastOld = path[splitIdx - 1];
    if (lastOld.isAssistant && lastOld.toolCalls.isNotEmpty) {
      splitIdx = splitIdx - 1 < 0 ? 0 : splitIdx - 1;
    }
  }

  return _Split(path.sublist(0, splitIdx), path.sublist(splitIdx));
}

/// Replaces old tool-result messages with compact stubs. The stored messages
/// are NOT mutated — this returns cloned copies with stub text. However, the
/// `cleared`/`clearedSummary`/`refetchArgs` fields ARE set on the original
/// stored messages (they're persisted state, like `originalContent`).
///
/// [fullPath] is needed to find the parent assistant message whose ToolCall
/// args populate `refetchArgs`.
List<ChatMessage> _clearOldToolResults(
  List<ChatMessage> oldMessages,
  List<ChatMessage> fullPath,
  Set<String> currentTurnMessageIds,
) {
  if (oldMessages.isEmpty) return oldMessages;

  // Index parent assistant messages by id for refetchArgs lookup.
  final byId = {for (final m in fullPath) m.id: m};

  final result = <ChatMessage>[];
  for (final m in oldMessages) {
    if (m.role != MessageRole.tool || currentTurnMessageIds.contains(m.id)) {
      result.add(m);
      continue;
    }

    // Find the parent assistant message to get the tool call args.
    ChatMessage? parent;
    if (m.parentId != null) {
      parent = byId[m.parentId!];
    }
    ToolCall? call;
    if (parent != null && m.toolCallId != null) {
      call = parent.toolCalls.where((tc) => tc.id == m.toolCallId).firstOrNull;
    }

    // Mark the stored message as cleared (persisted state).
    m.cleared = true;
    m.clearedSummary ??= _summarizeToolResult(m.text);
    if (call != null && call.args.isNotEmpty) {
      m.refetchArgs ??= _safeDecodeArgs(call.args);
    }
    _log.fine(
      'cleared tool result: id=${m.id} tool=${call?.name ?? "?"} '
      'summary=${m.clearedSummary}',
    );

    // Build a stub clone for the request.
    result.add(
      ChatMessage(
        id: m.id,
        role: m.role,
        text: _stubText(m, call),
        createdAt: m.createdAt,
        toolCallId: m.toolCallId,
        parentId: m.parentId,
        children: m.childrenIds,
      ),
    );
  }
  return result;
}

String _summarizeToolResult(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return 'empty result';
  // First non-empty line, truncated.
  final firstLine = trimmed
      .split('\n')
      .firstWhere((l) => l.trim().isNotEmpty, orElse: () => trimmed);
  return firstLine.length > 100 ? '${firstLine.substring(0, 100)}…' : firstLine;
}

Map<String, Object?>? _safeDecodeArgs(String args) {
  if (args.isEmpty) return null;
  try {
    final decoded = jsonDecode(args);
    if (decoded is Map<String, Object?>) return decoded;
  } catch (_) {}
  return null;
}

String _stubText(ChatMessage m, ToolCall? call) {
  final buf = StringBuffer('[Tool result cleared]');
  if (call != null) {
    buf.writeln();
    buf.write('tool: ${call.name}');
  }
  if (m.clearedSummary != null) {
    buf.writeln();
    buf.write('summary: ${m.clearedSummary}');
  }
  if (call != null && call.args.isNotEmpty) {
    buf.writeln();
    buf.write('refetch: ${call.name}(${call.args})');
  }
  return buf.toString();
}

/// Compacts old messages into a rolling summary via an LLM call.
///
/// Implemented as an abstract class so the repository can inject the adapter
/// without this file depending on `llm_adapter.dart` (avoids import cycles).
abstract class ContextCompactor {
  /// Compacts [oldMessages] into a summary, returning [summary, ...recentTail].
  /// On error, implementations should return the inputs unchanged (fail safe).
  Future<List<ChatMessage>> compact(
    List<ChatMessage> oldMessages,
    List<ChatMessage> recentTail,
  );
}
