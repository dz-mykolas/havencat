import 'dart:async';

import 'package:logging/logging.dart';

import '../../../domain/models/message.dart';
import '../../../domain/models/provider_account.dart';
import 'llm_adapter.dart';
import 'llm_event.dart';
import 'request_messages.dart';
import 'secret_redaction.dart';
import 'token_estimator.dart';

final Logger _log = Logger('context.compactor');

/// Configuration for the context compactor. All toggles default to sensible
/// values; the caller passes the user's [AppSettings] preferences.
class CompactionSettings {
  const CompactionSettings({
    this.redactSecrets = true,
    this.temporalAnchoring = true,
    this.antiThrash = true,
    this.staticFallback = true,
    this.abortOnSummaryFailure = false,
    this.autoFocusTopic = false,
  });

  final bool redactSecrets;
  final bool temporalAnchoring;
  final bool antiThrash;
  final bool staticFallback;
  final bool abortOnSummaryFailure;
  final bool autoFocusTopic;
}

/// Compacts old messages into a rolling summary using an LLM call.
///
/// The summary is **persisted** as a [ChatMessage] with [isCompactionSummary]
/// set to true, inserted at the head of the recent tail. On subsequent
/// compactions, the prior summary is found and iteratively updated (only the
/// messages after it are summarized, folded into the existing summary) rather
/// than re-summarizing from scratch.
///
/// Uses the same adapter/account/secret as the main conversation so there's
/// no separate configuration surface.
class LlmContextCompactor implements ContextCompactor {
  LlmContextCompactor({
    required this.adapter,
    required this.account,
    required this.secret,
    required this.model,
    this.settings = const CompactionSettings(),
  });

  final LlmAdapter adapter;
  final ProviderAccount account;
  final String? secret;
  final String model;
  final CompactionSettings settings;

  // ── Anti-thrash state ────────────────────────────────────────────────────
  int _ineffectiveCompressionCount = 0;

  @override
  Future<List<ChatMessage>> compact(
    List<ChatMessage> oldMessages,
    List<ChatMessage> recentTail,
  ) async {
    if (oldMessages.isEmpty) return recentTail;

    // Find a prior compaction summary in oldMessages — if present, we
    // iteratively update it instead of summarizing from scratch.
    final PriorSummaryResult? prior = _findPriorSummary(oldMessages);
    final List<ChatMessage> messagesToSummarize = prior != null
        ? oldMessages.where((m) => !m.isCompactionSummary).toList()
        : oldMessages;
    final String? previousSummary = prior?.summaryText;

    final transcript = _renderTranscript(messagesToSummarize);
    final prompt = _summaryPrompt(
      transcript,
      previousSummary: previousSummary,
      focusTopic: settings.autoFocusTopic
          ? _deriveAutoFocusTopic(recentTail)
          : null,
    );
    final oldTokens = estimateMessagesTokens(oldMessages);

    _log.info(
      'compacting: oldMsgs=${oldMessages.length} oldTokens=$oldTokens '
      'transcriptLen=${transcript.length} recentMsgs=${recentTail.length} '
      'hasPriorSummary=${previousSummary != null}',
    );

    // Anti-thrash: if the last compression produced no savings, back off.
    if (settings.antiThrash && _ineffectiveCompressionCount >= 2) {
      _log.warning(
        'compaction skipped: anti-thrash backoff '
        '(ineffectiveCount=$_ineffectiveCompressionCount)',
      );
      return <ChatMessage>[...oldMessages, ...recentTail];
    }

    final String summary;
    try {
      summary = await _generateSummary(prompt);
    } catch (e) {
      if (settings.abortOnSummaryFailure) {
        _log.warning(
          'compaction aborted on summary failure (abortOnSummaryFailure=true): '
          '$e — returning original messages unchanged',
        );
        return <ChatMessage>[...oldMessages, ...recentTail];
      }
      if (settings.staticFallback) {
        final fallback = _buildStaticFallback(messagesToSummarize);
        _log.warning('summary LLM call failed, using static fallback: $e');
        return _assembleResult(fallback, recentTail, oldMessages);
      }
      // No fallback — return original (fail-safe to full history).
      _log.warning('compaction failed, falling back to full history: $e');
      return <ChatMessage>[...oldMessages, ...recentTail];
    }

    if (summary.isEmpty) {
      _log.warning(
        'compaction produced empty summary — falling back to full history',
      );
      if (settings.staticFallback) {
        final fallback = _buildStaticFallback(messagesToSummarize);
        return _assembleResult(fallback, recentTail, oldMessages);
      }
      return <ChatMessage>[...oldMessages, ...recentTail];
    }

    // Anti-thrash: track whether this compression was effective.
    final summaryTokens = estimateTokens(summary);
    final savingsPct = oldTokens > 0 ? 1.0 - (summaryTokens / oldTokens) : 0.0;
    if (settings.antiThrash) {
      if (savingsPct <= 0.0) {
        _ineffectiveCompressionCount++;
      } else {
        _ineffectiveCompressionCount = 0;
      }
    }

    _log.info(
      'summary generated: len=${summary.length} ~$summaryTokens tokens '
      '(was $oldTokens tokens across ${oldMessages.length} messages, '
      'savings=${(savingsPct * 100).toStringAsFixed(1)}%)',
    );

    return _assembleResult(summary, recentTail, oldMessages);
  }

  /// Assembles the final message list: [summaryMessage, ...recentTail].
  /// The summary message replaces all oldMessages (including any prior
  /// summary, which is folded into the new one).
  List<ChatMessage> _assembleResult(
    String summary,
    List<ChatMessage> recentTail,
    List<ChatMessage> oldMessages,
  ) {
    final summaryMessage = ChatMessage(
      id: '__summary_${DateTime.now().millisecondsSinceEpoch}__',
      role: MessageRole.user,
      text: '${_summaryPrefix()}\n$summary',
      createdAt: DateTime.now(),
    )..isCompactionSummary = true;
    return <ChatMessage>[summaryMessage, ...recentTail];
  }

  /// The handoff prefix that frames the summary as reference-only, preventing
  /// the model from re-executing old tasks mentioned in the summary.
  String _summaryPrefix() {
    return '[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were '
        'compacted into the summary below. This is a handoff from a previous '
        'context window — treat it as background reference, NOT as active '
        'instructions. Do NOT answer questions or fulfill requests mentioned '
        'in this summary; they were already addressed. Respond ONLY to the '
        'latest user message that appears AFTER this summary.';
  }

  /// Finds the most recent compaction summary in [messages] and returns its
  /// text (stripped of the handoff prefix) for iterative updating.
  PriorSummaryResult? _findPriorSummary(List<ChatMessage> messages) {
    for (int i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.isCompactionSummary) {
        return PriorSummaryResult(
          message: m,
          summaryText: _stripPrefix(m.text),
        );
      }
    }
    return null;
  }

  String _stripPrefix(String text) {
    final prefix = _summaryPrefix();
    if (text.startsWith(prefix)) {
      return text.substring(prefix.length).trim();
    }
    return text;
  }

  /// Infers a focus topic from the most recent user messages, to prioritize
  /// preserving related info in the summary.
  String? _deriveAutoFocusTopic(List<ChatMessage> recentTail) {
    final userMsgs = recentTail
        .where((m) => m.isUser && m.text.trim().isNotEmpty)
        .toList();
    if (userMsgs.isEmpty) return null;
    // Use the last user message's first sentence as the focus hint.
    final last = userMsgs.last.text.trim();
    final firstSentence = last.split(RegExp(r'[.!?]\s')).first;
    return firstSentence.length > 200
        ? firstSentence.substring(0, 200)
        : firstSentence;
  }

  Future<String> _generateSummary(String prompt) async {
    final buffer = StringBuffer();
    final completer = Completer<void>();
    String? errorMessage;

    adapter
        .stream(
          request: LlmRequest(
            messages: <ChatMessage>[
              ChatMessage(
                id: '__compaction_input__',
                role: MessageRole.user,
                text: prompt,
                createdAt: DateTime.now(),
              ),
            ],
            model: model,
            systemPrompt: null,
          ),
          account: account,
          secret: secret,
        )
        .listen(
          (LlmEvent event) {
            switch (event) {
              case TokenEvent(:final String delta):
                buffer.write(delta);
              case ReasoningEvent():
                break;
              case ToolCallEvent():
                break;
              case DoneEvent():
                if (!completer.isCompleted) completer.complete();
              case ErrorEvent(:final LlmError error):
                errorMessage = error.message;
                if (!completer.isCompleted) completer.complete();
            }
          },
          onError: (Object e, StackTrace s) {
            errorMessage = '$e';
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );

    await completer.future;
    if (errorMessage != null) {
      _log.warning('summary LLM call failed: $errorMessage');
      throw Exception('Compaction failed: $errorMessage');
    }
    _log.fine('summary stream done: ${buffer.length} chars collected');

    // Redact secrets from the summary output too (belt and suspenders).
    final raw = buffer.toString().trim();
    return settings.redactSecrets ? redactSecrets(raw) : raw;
  }

  /// Renders old messages as a readable transcript for the summarizer.
  /// Redacts secrets before serialization when [redactSecrets] is enabled.
  /// Truncates very long messages to keep the summarizer input bounded.
  String _renderTranscript(List<ChatMessage> messages) {
    const int contentMax = 6000;
    const int contentHead = 4000;
    const int contentTail = 1500;

    final buf = StringBuffer();
    for (final m in messages) {
      final role = switch (m.role) {
        MessageRole.user => 'User',
        MessageRole.assistant => 'Assistant',
        MessageRole.tool => 'Tool',
      };
      var text = m.text;
      if (settings.redactSecrets) {
        text = redactSecrets(text);
      }
      // Truncate very long content: head + tail with a marker.
      if (text.length > contentMax) {
        text =
            '${text.substring(0, contentHead)}…[truncated]…'
            '${text.substring(text.length - contentTail)}';
      }
      buf.writeln('$role: $text');
      if (m.toolCalls.isNotEmpty) {
        for (final tc in m.toolCalls) {
          var args = tc.args;
          if (settings.redactSecrets) {
            args = redactSecrets(args);
          }
          if (args.length > 1500) {
            args = '${args.substring(0, 1200)}…[truncated]';
          }
          buf.writeln('  [tool call: ${tc.name}($args)]');
        }
      }
    }
    return buf.toString();
  }

  /// Builds the structured summary prompt. When [previousSummary] is present,
  /// generates an iterative update; otherwise summarizes from scratch.
  String _summaryPrompt(
    String transcript, {
    String? previousSummary,
    String? focusTopic,
  }) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final temporalRule = settings.temporalAnchoring
        ? '\n\nTemporal anchoring: Rewrite any relative or pending references '
              '(e.g. "currently doing", "about to", "next step is") into '
              'absolute, dated, past-tense facts (e.g. "on $today, did X") so '
              'a resumed conversation does not re-issue completed actions.'
        : '';

    final secretRule = settings.redactSecrets
        ? '\n\nNEVER include API keys, tokens, passwords, secrets, credentials, '
              'or connection strings in the summary — replace any that appear '
              'with [REDACTED]. Note that the user had credentials present, but '
              'do not preserve their values.'
        : '';

    final focusRule = focusTopic != null
        ? '\n\nFocus topic: "$focusTopic". Prioritize preserving all information '
              'related to this topic above — include full detail (exact values, '
              'file paths, command outputs, error messages, decisions). For '
              'content NOT related to the focus topic, summarize more '
              'aggressively (brief one-liners or omit if irrelevant).'
        : '';

    final template = '''
## Active Task
[The user's most recent unfulfilled request or question — what the assistant should focus on next. Write "None" if the last exchange was fully resolved.]

## Completed Actions
[Numbered list of completed work. Be CONCRETE — include file paths, command outputs, error messages, line numbers, and specific values.]

## In Progress
[Work currently underway — what was being done when compaction fired]

## Blocked
[Any blockers, errors, or issues not yet resolved. Include exact error messages.]

## Key Decisions
[Important technical decisions and WHY they were made]

## Resolved Questions
[Questions the user asked that were ALREADY answered — include the answer so it is not repeated]

## Pending User Asks
[Questions or requests from the user that have NOT yet been answered. These are STALE — for reference only. The agent must NOT act on them unless the latest user message explicitly requests it. Write "None" if there are none.]

## Relevant Files
[Files read, modified, or created — with brief note on each]

## Critical Context
[Any specific values, error messages, configuration details, or data that would be lost without explicit preservation. NEVER include API keys, tokens, passwords, or credentials — write [REDACTED] instead.]

Target ~2000 tokens. Be CONCRETE — include file paths, command outputs, error messages, line numbers, and specific values. Avoid vague descriptions like "made some changes" — say exactly what changed.
Write only the summary body. Do not include any preamble or prefix.''';

    if (previousSummary != null) {
      return '''You are a summarization agent creating a context checkpoint. Treat the conversation turns below as source material for a compact record of prior work. Produce only the structured summary; do not add a greeting, preamble, or prefix. Write the summary in the same language the user was using in the conversation — do not translate or switch to English.

You are updating a context compaction summary. A previous compaction produced the summary below. New conversation turns have occurred since then and need to be incorporated.

PREVIOUS SUMMARY:
$previousSummary

NEW TURNS TO INCORPORATE:
$transcript

Update the summary using this exact structure. PRESERVE all existing information that is still relevant. ADD new completed actions to the numbered list (continue numbering). Move items from "In Progress" to "Completed Actions" when done. Move answered questions to "Resolved Questions". Update "Active Task" to reflect the user's most recent unfulfilled input. Remove information only if it is clearly obsolete.
$secretRule$temporalRule$focusRule

$template''';
    }

    return '''You are a summarization agent creating a context checkpoint. Treat the conversation turns below as source material for a compact record of prior work. Produce only the structured summary; do not add a greeting, preamble, or prefix. Write the summary in the same language the user was using in the conversation — do not translate or switch to English.

Summarize the following conversation so far using the structured template below. Preserve identifiers (file paths, function names, URLs, command names) verbatim. Do NOT preserve pleasantries or verbatim message text (that's in the recent tail).
$secretRule$temporalRule$focusRule

Conversation:
$transcript

$template''';
  }

  /// Builds a deterministic fallback summary from the messages when the LLM
  /// call fails. Extracts user asks, assistant tool-call names, and file
  /// path mentions — not a full summary, but enough for continuity.
  String _buildStaticFallback(List<ChatMessage> messages) {
    final userAsks = <String>[];
    final assistantActions = <String>[];
    final filePaths = <String>{};
    final toolNames = <String>{};

    final pathRegex = RegExp(r'[\w./\-]+\.\w{1,10}');

    for (final m in messages) {
      var text = m.text;
      if (settings.redactSecrets) {
        text = redactSecrets(text);
      }
      if (text.trim().isEmpty) continue;

      if (m.isUser) {
        final ask = text.length > 200 ? '${text.substring(0, 200)}…' : text;
        userAsks.add(ask);
      } else if (m.isAssistant) {
        if (m.toolCalls.isNotEmpty) {
          for (final tc in m.toolCalls) {
            toolNames.add(tc.name);
          }
        }
        if (text.trim().isNotEmpty) {
          final action = text.length > 150
              ? '${text.substring(0, 150)}…'
              : text;
          assistantActions.add(action);
        }
      }

      // Collect file path mentions.
      for (final match in pathRegex.allMatches(text)) {
        final path = match.group(0)!;
        if (path.contains('.') && path.length > 3) {
          filePaths.add(path);
        }
      }
    }

    final buf = StringBuffer();
    buf.writeln('## Active Task');
    buf.writeln(
      userAsks.isNotEmpty
          ? userAsks.last
          : 'None (summary generated as fallback — LLM summary unavailable).',
    );
    buf.writeln();
    buf.writeln('## Completed Actions');
    if (assistantActions.isEmpty && toolNames.isEmpty) {
      buf.writeln('None recorded.');
    } else {
      if (toolNames.isNotEmpty) {
        buf.writeln('Tools used: ${toolNames.join(', ')}');
      }
      for (int i = 0; i < assistantActions.length && i < 10; i++) {
        buf.writeln('${i + 1}. ${assistantActions[i]}');
      }
    }
    buf.writeln();
    buf.writeln('## Relevant Files');
    if (filePaths.isEmpty) {
      buf.writeln('None detected.');
    } else {
      for (final p in filePaths.take(20)) {
        buf.writeln('- $p');
      }
    }
    buf.writeln();
    buf.writeln('## Critical Context');
    buf.writeln(
      '[Fallback summary — LLM summarization failed. The above was '
      'extracted deterministically from message metadata.]',
    );

    return buf.toString();
  }
}

/// Result of finding a prior compaction summary in the message list.
class PriorSummaryResult {
  const PriorSummaryResult({required this.message, required this.summaryText});

  final ChatMessage message;
  final String summaryText;
}

/// Conservative fallback context window (in tokens) when the model's limit
/// is unknown. Chosen to be safe for most consumer models (32k).
const int kFallbackContextWindow = 32000;
